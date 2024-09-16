// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Counter} from "../src/Counter.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {Slot0} from "v4-core/src/types/Slot0.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract DirectionalFeeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    Counter hook;
    PoolId poolId;
    uint24 poolFee = 500;
    uint128 poolLiquidity = 10_000 ether;
    int24 tickSpacing = 10;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG |
                    // Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.AFTER_INITIALIZE_FLAG
            ) ^ (0x4445 << 144) // Namespace the hook to avoid collisions
        );

        deployCodeTo(
            "DirectionalFee.sol:DirectionalFee",
            abi.encode(manager),
            flags
        );

        hook = Counter(flags);

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing,
            IHooks(hook)
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide full-range liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(tickSpacing),
                TickMath.maxUsableTick(tickSpacing),
                int128(poolLiquidity),
                0
            ),
            ZERO_BYTES
        );
    }

    function test_dynamicFee_ZeroForOne_multipleBlocks() public {
        // positions were created in setup()

        // Perform a test swap //
        bool zeroForOne = true;
        // negative number indicates exact input swap!
        int256 amountSpecified = -10e18;

        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );

        vm.roll(2);

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        // ------------------- //

        assertEq(int256(swapDelta.amount0()), amountSpecified);
    }

    function test_dynamicFee_OneForZero_multipleBlocks() public {
        // positions were created in setup()
        uint24 lpFeePreSwap = _fetchPoolLPFee(key);
        assertEq(lpFeePreSwap, poolFee);

        // Perform a test swap
        bool zeroForOne = false;
        int128 amountSpecified = -10e18;

        vm.expectEmit(true, false, false, true);
        emit IPoolManager.Swap(
            key.toId(),
            address(swapRouter),
            9985019972537448819,
            amountSpecified,
            79307351062697344798968697514,
            poolLiquidity,
            19,
            poolFee
        );

        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );

        assertEq(int256(swapDelta.amount1()), amountSpecified);

        vm.roll(2);

        uint24 expectedFee = 799;

        vm.expectEmit(true, false, false, true);
        emit IPoolManager.Swap(
            key.toId(),
            address(swapRouter),
            9962121655543364430,
            amountSpecified,
            79386515921909760239356504222,
            poolLiquidity,
            39,
            expectedFee
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        // since we did the swap in the same direction
        // the fee should increase
        uint24 lpFeePostSwap = _fetchPoolLPFee(key);
        assertEq(lpFeePostSwap, expectedFee);
    }

    function test_dynamicFee_OneForZeroThenZeroForOne_shouldGiveHighLowDirectionalFee()
        public
    {
        // positions were created in setup()
        uint24 lpFeePreSwap = _fetchPoolLPFee(key);
        assertEq(lpFeePreSwap, poolFee);

        // Perform a test swap
        bool zeroForOne = false;
        int256 amountSpecified = -10e18;

        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );

        assertEq(int256(swapDelta.amount1()), amountSpecified);

        // Check the swap fee should not change in the same block
        (, , , uint24 lpFeePostSwap) = manager.getSlot0(key.toId());
        assertEq(lpFeePostSwap, poolFee);

        vm.roll(2);

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        (, , , uint24 lpFeePostSwapNewBlock) = manager.getSlot0(key.toId());

        // since we did the swap in the same direction
        // the fee should be higher
        assertGt(lpFeePostSwapNewBlock, poolFee);

        // swap in opposite direction should give lower fee
        zeroForOne = true;
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        (, , , uint24 newFee) = manager.getSlot0(key.toId());
        assertLt(newFee, poolFee);
    }

    function test_dynamicFee_ZeroForOneThenOneForZero_shouldGiveHighLowDirectionalFee()
        public
    {
        // positions were created in setup()
        uint24 lpFeePreSwap = _fetchPoolLPFee(key);
        assertEq(lpFeePreSwap, poolFee);

        // Perform a test swap zero for one
        bool zeroForOne = true;
        int256 amountSpecified = -10e18;

        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        // Check the swap fee should not change in the same block
        uint24 lpFeePostSwap = _fetchPoolLPFee(key);
        assertEq(lpFeePostSwap, poolFee);

        vm.roll(2);

        // Perform a test swap zero for one
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        uint24 lpFeePostSwapNewBlock = _fetchPoolLPFee(key);

        // since we did the swap in the same direction
        // the fee should be higher
        assertGt(lpFeePostSwapNewBlock, poolFee);

        // swap in opposite direction should give lower fee
        zeroForOne = false;
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        uint24 newFee = _fetchPoolLPFee(key);
        assertLt(newFee, poolFee);
    }

    function _fetchPoolLPFee(
        PoolKey memory _key
    ) internal view returns (uint24 lpFee) {
        PoolId id = _key.toId();
        (, , , lpFee) = manager.getSlot0(id);
    }
}
