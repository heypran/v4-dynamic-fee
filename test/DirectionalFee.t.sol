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
import {DynamicLPFeeLibrary} from "../src/DynamicFeeLibrary.sol";

contract DirectionalFeeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using DynamicLPFeeLibrary for uint24;

    Counter hook;
    PoolId poolId;
    uint24 poolFee = 3000;

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
            DynamicLPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(hook)
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        console.log("DynamicLPFeeLibrary.DYNAMIC_FEE_FLAG");
        console.logUint(DynamicLPFeeLibrary.DYNAMIC_FEE_FLAG);
        // Provide full-range liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                10_000 ether,
                0
            ),
            ZERO_BYTES
        );
    }

    function testDynamicFeeHooks() public {
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

    function testFeeOneForZero() public {
        // positions were created in setup()
        (, , , uint24 lpFeePreSwap) = manager.getSlot0(key.toId());
        assertEq(lpFeePreSwap, poolFee);

        // Perform a test swap
        bool zeroForOne = false;
        int256 amountSpecified = -10e18;

        // TODO
        vm.expectEmit(true, false, false, false);
        emit IPoolManager.Swap(key.toId(), address(0), 0, 0, 0, 0, 0, poolFee);

        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );
        assertEq(int256(swapDelta.amount1()), amountSpecified);

        vm.roll(2);

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        // since we did the swap in the same direction
        // the fee should increase
        (, , , uint24 lpFeePostSwap) = manager.getSlot0(key.toId());
        assertGt(lpFeePostSwap, poolFee);
    }

    function testFeeOneForZeroThenZeroForOne() public {
        // positions were created in setup()
        (, , , uint24 lpFeePreSwap) = manager.getSlot0(key.toId());
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

    function testFeeZeroForOneThenOneForZero() public {
        // positions were created in setup()
        (, , , uint24 lpFeePreSwap) = manager.getSlot0(key.toId());
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
        (, , , uint24 lpFeePostSwap) = manager.getSlot0(key.toId());
        assertEq(lpFeePostSwap, poolFee);

        vm.roll(2);

        // Perform a test swap zero for one
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        (, , , uint24 lpFeePostSwapNewBlock) = manager.getSlot0(key.toId());

        // since we did the swap in the same direction
        // the fee should be higher
        assertGt(lpFeePostSwapNewBlock, poolFee);

        // swap in opposite direction should give lower fee
        zeroForOne = false;
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        (, , , uint24 newFee) = manager.getSlot0(key.toId());
        assertLt(newFee, poolFee);
    }
}
