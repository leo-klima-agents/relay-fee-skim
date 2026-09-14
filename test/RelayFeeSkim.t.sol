// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {RelayFeeSkim} from "../src/RelayFeeSkim.sol";
import {IRelayEntrypoint} from "../src/interfaces/IRelayEntrypoint.sol";
import {MockERC20, NoReturnERC20, ReentrantERC20, ReturnsFalseERC20} from "./mocks/MockERC20.sol";
import {MockRelay, NoopPullRelay} from "./mocks/MockRelay.sol";

contract RelayFeeSkimTest is Test {
    uint256 internal constant FEE_BPS = 500; // 5%
    uint256 internal constant BPS = 10_000;
    address internal constant SINK = address(0xFEE);

    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    RelayFeeSkim internal skimmer;
    MockRelay internal relay;

    // Three standard tokens with strictly ascending addresses.
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    // The real Voter rejects an empty claim request and any claim with zero checkpoints, so every
    // claim-path test sends one fee claim; the empty arrays exist only for the negative tests.
    IRelayEntrypoint.FeeClaim[] internal oneFeeClaim;
    IRelayEntrypoint.FeeClaim[] internal noFeeClaims;
    IRelayEntrypoint.IncentiveClaim[] internal noIncentiveClaims;

    function setUp() public {
        skimmer = new RelayFeeSkim(FEE_BPS, SINK);
        relay = new MockRelay();
        relay.grantRoles(keeper, relay.KEEPER());
        relay.grantRoles(address(skimmer), relay.CONVERTER());
        oneFeeClaim.push(IRelayEntrypoint.FeeClaim({votingRewardsManager: makeAddr("vrm"), maxCheckpoints: 1}));

        MockERC20[3] memory ts = [new MockERC20("A"), new MockERC20("B"), new MockERC20("C")];
        for (uint256 i = 1; i < 3; ++i) {
            for (uint256 j = i; j > 0 && address(ts[j]) < address(ts[j - 1]); --j) {
                (ts[j], ts[j - 1]) = (ts[j - 1], ts[j]);
            }
        }
        (tokenA, tokenB, tokenC) = (ts[0], ts[1], ts[2]);
        assertTrue(address(tokenA) < address(tokenB) && address(tokenB) < address(tokenC));
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _one(address t) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = t;
    }

    function _two(address t0, address t1) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = t0;
        a[1] = t1;
    }

    function _claimAndSkim(address caller, address[] memory tokens) internal returns (uint256[] memory fees) {
        vm.prank(caller);
        fees = skimmer.claimAndSkim(address(relay), oneFeeClaim, noIncentiveClaims, tokens);
    }

    function _fee(uint256 base, uint256 bps) internal pure returns (uint256) {
        return (base * bps) / BPS;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_storesImmutables() public view {
        assertEq(skimmer.FEE_BPS(), FEE_BPS);
        assertEq(skimmer.FEE_SINK(), SINK);
        assertEq(skimmer.BPS(), 10_000);
        assertEq(skimmer.MAX_FEE_BPS(), 1000);
    }

    function test_constructor_revertsZeroFee() public {
        vm.expectRevert(RelayFeeSkim.FeeOutOfRange.selector);
        new RelayFeeSkim(0, SINK);
    }

    function test_constructor_revertsFeeAboveCap() public {
        vm.expectRevert(RelayFeeSkim.FeeOutOfRange.selector);
        new RelayFeeSkim(1001, SINK);
    }

    function test_constructor_acceptsCap() public {
        RelayFeeSkim s = new RelayFeeSkim(1000, SINK);
        assertEq(s.FEE_BPS(), 1000);
    }

    function test_constructor_revertsZeroSink() public {
        vm.expectRevert(RelayFeeSkim.ZeroAddress.selector);
        new RelayFeeSkim(FEE_BPS, address(0));
    }

    function testFuzz_constructor_bound(uint256 bps) public {
        if (bps == 0 || bps > 1000) {
            vm.expectRevert(RelayFeeSkim.FeeOutOfRange.selector);
            new RelayFeeSkim(bps, SINK);
        } else {
            RelayFeeSkim s = new RelayFeeSkim(bps, SINK);
            assertEq(s.FEE_BPS(), bps);
            assertEq(s.FEE_SINK(), SINK);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             claimAndSkim
    //////////////////////////////////////////////////////////////*/

    function test_claimAndSkim_callableByStranger() public {
        relay.setClaimable(address(tokenA), 10_000);

        uint256[] memory fees = _claimAndSkim(stranger, _one(address(tokenA)));

        assertEq(fees.length, 1);
        assertEq(fees[0], 500);
        assertEq(tokenA.balanceOf(SINK), 500);
        assertEq(tokenA.balanceOf(address(relay)), 9500);
        assertEq(tokenA.balanceOf(address(skimmer)), 0);
        assertEq(relay.claimCalls(), 1);
    }

    function test_claimAndSkim_feeOnDeltaOnly_preBalanceUntouched() public {
        tokenA.mint(address(relay), 100_000); // pre-existing, must not be taxed
        relay.setClaimable(address(tokenA), 10_000);

        uint256[] memory fees = _claimAndSkim(stranger, _one(address(tokenA)));

        assertEq(fees[0], _fee(10_000, FEE_BPS));
        assertEq(tokenA.balanceOf(SINK), 500);
        assertEq(tokenA.balanceOf(address(relay)), 100_000 + 10_000 - 500);
    }

    function test_claimAndSkim_emitsSkimmed() public {
        relay.setClaimable(address(tokenA), 10_000);

        vm.expectEmit(address(skimmer));
        emit RelayFeeSkim.Skimmed(address(relay), address(tokenA), 10_000, 500);
        _claimAndSkim(stranger, _one(address(tokenA)));
    }

    function test_claimAndSkim_repeatRevertsNoFee() public {
        relay.setClaimable(address(tokenA), 10_000);
        _claimAndSkim(stranger, _one(address(tokenA)));

        // Second claim yields nothing; the 9_500 still on the Relay is not a claim delta.
        vm.expectRevert(RelayFeeSkim.NoFee.selector);
        _claimAndSkim(stranger, _one(address(tokenA)));
        assertEq(tokenA.balanceOf(address(relay)), 9500);
    }

    function test_claimAndSkim_nothingClaimableRevertsNoFee() public {
        tokenA.mint(address(relay), 100_000);
        vm.expectRevert(RelayFeeSkim.NoFee.selector);
        _claimAndSkim(stranger, _one(address(tokenA)));
    }

    function test_claimAndSkim_emptyClaimsRejectedByRelay() public {
        relay.setClaimable(address(tokenA), 10_000);
        // Upstream the Voter refuses a request with no claims at all; the revert is the Relay's, not ours.
        vm.expectRevert(MockRelay.EmptyClaimRewardsParams.selector);
        vm.prank(stranger);
        skimmer.claimAndSkim(address(relay), noFeeClaims, noIncentiveClaims, _one(address(tokenA)));
    }

    function test_claimAndSkim_zeroCheckpointsRejectedByRelay() public {
        relay.setClaimable(address(tokenA), 10_000);
        IRelayEntrypoint.FeeClaim[] memory bad = new IRelayEntrypoint.FeeClaim[](1);
        bad[0] = IRelayEntrypoint.FeeClaim({votingRewardsManager: makeAddr("vrm"), maxCheckpoints: 0});

        vm.expectRevert(MockRelay.ZeroCheckpoints.selector);
        vm.prank(stranger);
        skimmer.claimAndSkim(address(relay), bad, noIncentiveClaims, _one(address(tokenA)));
    }

    function test_claimAndSkim_incentiveClaimOnly() public {
        relay.setClaimable(address(tokenA), 10_000);
        IRelayEntrypoint.IncentiveClaim[] memory inc = new IRelayEntrypoint.IncentiveClaim[](1);
        inc[0] =
            IRelayEntrypoint.IncentiveClaim({votingRewardsManager: makeAddr("vrm"), programId: 7, maxCheckpoints: 3});

        vm.prank(stranger);
        uint256[] memory fees = skimmer.claimAndSkim(address(relay), noFeeClaims, inc, _one(address(tokenA)));

        assertEq(fees[0], 500);
        assertEq(relay.claimCalls(), 1);
    }

    function test_claimAndSkim_emptyTokensRevertsNoFee() public {
        relay.setClaimable(address(tokenA), 10_000);
        vm.expectRevert(RelayFeeSkim.NoFee.selector);
        _claimAndSkim(stranger, new address[](0));
    }

    function test_claimAndSkim_multiToken_skipsEmpty() public {
        relay.setClaimable(address(tokenA), 10_000);
        relay.setClaimable(address(tokenC), 2000);
        tokenB.mint(address(relay), 50_000); // present but nothing claimed

        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(tokenA), address(tokenB), address(tokenC));

        uint256[] memory fees = _claimAndSkim(stranger, tokens);

        assertEq(fees[0], 500);
        assertEq(fees[1], 0);
        assertEq(fees[2], 100);
        assertEq(tokenA.balanceOf(SINK), 500);
        assertEq(tokenB.balanceOf(SINK), 0);
        assertEq(tokenB.balanceOf(address(relay)), 50_000);
        assertEq(tokenC.balanceOf(SINK), 100);
    }

    function test_claimAndSkim_revertsUnsorted() public {
        relay.setClaimable(address(tokenA), 10_000);
        vm.expectRevert(RelayFeeSkim.TokensNotSorted.selector);
        _claimAndSkim(stranger, _two(address(tokenB), address(tokenA)));
    }

    function test_claimAndSkim_revertsDuplicate() public {
        relay.setClaimable(address(tokenA), 10_000);
        vm.expectRevert(RelayFeeSkim.TokensNotSorted.selector);
        _claimAndSkim(stranger, _two(address(tokenA), address(tokenA)));
    }

    function test_claimAndSkim_revertsWithoutPullRole() public {
        relay.revokeRoles(address(skimmer), relay.CONVERTER());
        relay.setClaimable(address(tokenA), 10_000);

        vm.expectRevert(MockRelay.NotAuthorized.selector);
        _claimAndSkim(stranger, _one(address(tokenA)));
    }

    function test_claimAndSkim_worksWithCompounderRoleToo() public {
        relay.revokeRoles(address(skimmer), relay.CONVERTER());
        relay.grantRoles(address(skimmer), relay.COMPOUNDER());
        relay.setClaimable(address(tokenA), 10_000);

        uint256[] memory fees = _claimAndSkim(stranger, _one(address(tokenA)));
        assertEq(fees[0], 500);
    }

    function testFuzz_claimAndSkim(uint128 pre, uint128 delta, uint256 bps) public {
        bps = bound(bps, 1, 1000);
        RelayFeeSkim s = new RelayFeeSkim(bps, SINK);
        relay.grantRoles(address(s), relay.CONVERTER());

        tokenA.mint(address(relay), pre);
        relay.setClaimable(address(tokenA), delta);

        uint256 expected = _fee(delta, bps);
        if (expected == 0) {
            vm.expectRevert(RelayFeeSkim.NoFee.selector);
            vm.prank(stranger);
            s.claimAndSkim(address(relay), oneFeeClaim, noIncentiveClaims, _one(address(tokenA)));
            return;
        }

        vm.prank(stranger);
        uint256[] memory fees = s.claimAndSkim(address(relay), oneFeeClaim, noIncentiveClaims, _one(address(tokenA)));

        assertEq(fees[0], expected);
        assertLe(fees[0] * BPS, uint256(delta) * bps, "fee exceeds share of delta");
        assertGe(tokenA.balanceOf(address(relay)), pre, "pre-existing balance touched");
        assertEq(tokenA.balanceOf(address(relay)), uint256(pre) + delta - expected);
        assertEq(tokenA.balanceOf(SINK), expected);
        assertEq(tokenA.balanceOf(address(s)), 0, "skimmer retained tokens");
    }

    function test_claimAndSkim_reentrantTokenReverts() public {
        ReentrantERC20 rt = new ReentrantERC20(skimmer, address(relay));
        relay.setClaimable(address(rt), 10_000);

        // The reentrant claimAndSkim hits the lock; its revert bubbles out of the token's `transfer`,
        // which the skimmer reports as a failed transfer.
        vm.expectRevert(RelayFeeSkim.TransferFailed.selector);
        _claimAndSkim(stranger, _one(address(rt)));
    }

    function test_claimAndSkim_reentrantToken_lockIsTheCause() public {
        ReentrantERC20 rt = new ReentrantERC20(skimmer, address(relay));
        rt.setRecord(true);
        relay.setClaimable(address(rt), 10_000);

        uint256[] memory fees = _claimAndSkim(stranger, _one(address(rt)));

        assertTrue(rt.reentered());
        assertEq(rt.lastRevert(), abi.encodeWithSelector(RelayFeeSkim.Reentrancy.selector));
        assertEq(fees[0], 500);
        assertEq(rt.balanceOf(SINK), 500);
        assertEq(rt.balanceOf(address(skimmer)), 0);
    }

    function test_skim_reentrantToken_lockIsTheCause() public {
        ReentrantERC20 rt = new ReentrantERC20(skimmer, address(relay));
        rt.setMode(ReentrantERC20.Mode.Skim);
        rt.setRecord(true);
        relay.grantRoles(address(rt), relay.KEEPER()); // even a keeper cannot reenter
        rt.mint(address(relay), 10_000);

        vm.prank(keeper);
        uint256 fee = skimmer.skim(address(relay), address(rt));

        assertTrue(rt.reentered());
        assertEq(rt.lastRevert(), abi.encodeWithSelector(RelayFeeSkim.Reentrancy.selector));
        assertEq(fee, 500);
    }

    /*//////////////////////////////////////////////////////////////
                                 skim
    //////////////////////////////////////////////////////////////*/

    function test_skim_nonKeeperRevertsBeforeAnyRead() public {
        tokenA.mint(address(relay), 10_000);
        // A codeless token: any balance read would revert with empty data, not NotKeeper.
        address codeless = address(0xC0DE1E55);
        assertEq(codeless.code.length, 0);

        vm.expectRevert(RelayFeeSkim.NotKeeper.selector);
        vm.prank(stranger);
        skimmer.skim(address(relay), codeless);
    }

    function test_skim_revokedKeeperReverts() public {
        tokenA.mint(address(relay), 10_000);
        relay.revokeRoles(keeper, relay.KEEPER());

        vm.expectRevert(RelayFeeSkim.NotKeeper.selector);
        vm.prank(keeper);
        skimmer.skim(address(relay), address(tokenA));
    }

    function test_skim_otherRolesWithoutKeeperRevert() public {
        tokenA.mint(address(relay), 10_000);
        address other = makeAddr("other");
        relay.grantRoles(other, relay.VOTER_ROLE() | relay.COMPOUNDER() | relay.CONVERTER());

        vm.expectRevert(RelayFeeSkim.NotKeeper.selector);
        vm.prank(other);
        skimmer.skim(address(relay), address(tokenA));
    }

    function test_skim_feeOnIdle_subtractsAccounted() public {
        tokenA.mint(address(relay), 10_000);
        relay.setAccountedBalance(address(tokenA), 4000); // owed to holders, untouchable

        vm.expectEmit(address(skimmer));
        emit RelayFeeSkim.Skimmed(address(relay), address(tokenA), 6000, 300);
        vm.prank(keeper);
        uint256 fee = skimmer.skim(address(relay), address(tokenA));

        assertEq(fee, 300);
        assertEq(tokenA.balanceOf(SINK), 300);
        assertEq(tokenA.balanceOf(address(relay)), 9700);
        assertGe(tokenA.balanceOf(address(relay)), relay.accountedBalance(address(tokenA)));
    }

    function test_skim_accountedAboveBalance_noFee() public {
        tokenA.mint(address(relay), 10_000);
        relay.setAccountedBalance(address(tokenA), 10_001);

        vm.expectRevert(RelayFeeSkim.NoFee.selector);
        vm.prank(keeper);
        skimmer.skim(address(relay), address(tokenA));
    }

    function test_skim_floorsToZero_noFee() public {
        tokenA.mint(address(relay), 19); // 19 * 500 / 10_000 = 0

        vm.expectRevert(RelayFeeSkim.NoFee.selector);
        vm.prank(keeper);
        skimmer.skim(address(relay), address(tokenA));
    }

    /// @dev Two consecutive skims take 1 - 0.95^2 = 9.75% of the original idle balance, not 5%. This
    ///      compounding on an un-refreshed base is why `skim` is KEEPER-gated and `claimAndSkim` is not.
    function test_skim_twiceCompounds() public {
        tokenA.mint(address(relay), 10_000);

        vm.prank(keeper);
        uint256 first = skimmer.skim(address(relay), address(tokenA));
        vm.prank(keeper);
        uint256 second = skimmer.skim(address(relay), address(tokenA));

        assertEq(first, 500);
        assertEq(second, 475);
        assertEq(tokenA.balanceOf(SINK), 975); // 10_000 * (1 - 0.95^2)
        assertEq(tokenA.balanceOf(address(relay)), 9025);
    }

    function test_skim_newInflowAfterDrainTaxedFresh() public {
        tokenA.mint(address(relay), 10_000);
        vm.prank(keeper);
        skimmer.skim(address(relay), address(tokenA));

        // Drain the Relay, as a compound/convert would.
        uint256 remaining = tokenA.balanceOf(address(relay));
        address elsewhere = makeAddr("elsewhere");
        vm.prank(address(relay));
        assertTrue(tokenA.transfer(elsewhere, remaining));
        vm.expectRevert(RelayFeeSkim.NoFee.selector);
        vm.prank(keeper);
        skimmer.skim(address(relay), address(tokenA));

        tokenA.mint(address(relay), 2000);
        vm.prank(keeper);
        uint256 fee = skimmer.skim(address(relay), address(tokenA));

        assertEq(fee, 100);
        assertEq(tokenA.balanceOf(SINK), 600);
    }

    function test_skim_revertsWithoutPullRole() public {
        tokenA.mint(address(relay), 10_000);
        relay.revokeRoles(address(skimmer), relay.CONVERTER());

        vm.expectRevert(MockRelay.NotAuthorized.selector);
        vm.prank(keeper);
        skimmer.skim(address(relay), address(tokenA));
    }

    function testFuzz_skim(uint128 balance, uint128 accounted, uint256 bps) public {
        bps = bound(bps, 1, 1000);
        RelayFeeSkim s = new RelayFeeSkim(bps, SINK);
        relay.grantRoles(address(s), relay.CONVERTER());

        tokenA.mint(address(relay), balance);
        relay.setAccountedBalance(address(tokenA), accounted);

        uint256 idle = balance > accounted ? balance - accounted : 0;
        uint256 expected = _fee(idle, bps);
        if (expected == 0) {
            vm.expectRevert(RelayFeeSkim.NoFee.selector);
            vm.prank(keeper);
            s.skim(address(relay), address(tokenA));
            return;
        }

        vm.prank(keeper);
        uint256 fee = s.skim(address(relay), address(tokenA));

        assertEq(fee, expected);
        assertLe(fee * BPS, idle * bps);
        assertGe(tokenA.balanceOf(address(relay)), accounted, "accounted balance touched");
        assertEq(tokenA.balanceOf(SINK), expected);
        assertEq(tokenA.balanceOf(address(s)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                TOKENS
    //////////////////////////////////////////////////////////////*/

    function test_token_noReturnData_works() public {
        NoReturnERC20 usdt = new NoReturnERC20();
        usdt.mint(address(relay), 10_000);

        vm.prank(keeper);
        uint256 fee = skimmer.skim(address(relay), address(usdt));

        assertEq(fee, 500);
        assertEq(usdt.balanceOf(SINK), 500);
        assertEq(usdt.balanceOf(address(relay)), 9500);
        assertEq(usdt.balanceOf(address(skimmer)), 0);
    }

    function test_token_returnsFalse_revertsTransferFailed() public {
        // The stub's pull is a no-op, so the only transfer that runs is the skimmer's own forward.
        NoopPullRelay stub = new NoopPullRelay();
        ReturnsFalseERC20 bad = new ReturnsFalseERC20();
        bad.mint(address(stub), 10_000);
        bad.mint(address(skimmer), 500);

        vm.expectRevert(RelayFeeSkim.TransferFailed.selector);
        vm.prank(keeper);
        skimmer.skim(address(stub), address(bad));
    }

    function test_token_strayBalanceForwarded() public {
        tokenA.mint(address(relay), 10_000);
        tokenA.mint(address(skimmer), 123); // stray

        vm.prank(keeper);
        uint256 fee = skimmer.skim(address(relay), address(tokenA));

        assertEq(fee, 500);
        assertEq(tokenA.balanceOf(SINK), 623);
        assertEq(tokenA.balanceOf(address(skimmer)), 0);
    }

    function test_token_strayBalanceForwarded_claimPath() public {
        relay.setClaimable(address(tokenA), 10_000);
        tokenA.mint(address(skimmer), 7);

        _claimAndSkim(stranger, _one(address(tokenA)));

        assertEq(tokenA.balanceOf(SINK), 507);
        assertEq(tokenA.balanceOf(address(skimmer)), 0);
    }
}
