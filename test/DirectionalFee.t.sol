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

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG) ^
                (0x4445 << 144) // Namespace the hook to avoid collisions
        );

        deployCodeTo(
            "DirectionalFee.sol:DirectionalFee",
            abi.encode(manager),
            flags
        );
        hook = Counter(flags);

        // Create the pool
        // 3000
        key = PoolKey(
            currency0,
            currency1,
            DynamicLPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(hook)
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

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
        int256 amountSpecified = -100e18; // negative number indicates exact input swap!

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
}
