// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

contract DirectionalFee is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    // using DynamicLPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------
    struct FeeConfig {
        uint64 lastblock;
        uint8 feeFactor;
        uint160 lastBlockSqrtX96;
    }

    // TODO dynamic pool based
    uint24 constant minLpFee = 500;

    mapping(PoolId => FeeConfig) public feeConfig;
    mapping(PoolId => mapping(bool zeroForOne => uint24 lpfee))
        public poolLpFee;

    error DynamicFeeNotEnabled();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false, //
                afterInitialize: true, //
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, //
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        if (!key.fee.isDynamicFee()) {
            revert DynamicFeeNotEnabled();
        }

        feeConfig[key.toId()].lastblock = uint64(block.number);
        feeConfig[key.toId()].lastBlockSqrtX96 = sqrtPriceX96;
        feeConfig[key.toId()].feeFactor = 80; // make configurable/dynamic

        poolLpFee[key.toId()][true] = minLpFee;
        poolLpFee[key.toId()][false] = minLpFee;

        poolManager.updateDynamicLPFee(key, minLpFee);

        return BaseHook.afterInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 lpFee = _getFee(key, params.zeroForOne);
        poolManager.updateDynamicLPFee(key, lpFee);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _getFee(
        PoolKey calldata key,
        bool zeroForOne
    ) internal returns (uint24 lpFee) {
        if (!isNewBlock(key)) {
            return poolLpFee[key.toId()][zeroForOne];
        }

        // do the math
        (uint160 currentSqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint160 lastBlockSqrtPriceX96 = feeConfig[key.toId()].lastBlockSqrtX96;

        if (currentSqrtPriceX96 == lastBlockSqrtPriceX96) {
            poolLpFee[key.toId()][zeroForOne] = minLpFee;
            poolLpFee[key.toId()][!zeroForOne] = minLpFee;
            return minLpFee;
        }

        (, uint256 relativeChange) = _calculateDeltaChange(
            currentSqrtPriceX96,
            lastBlockSqrtPriceX96
        );

        uint256 deltaFee = (feeConfig[key.toId()].feeFactor * relativeChange) /
            100;

        uint24 modDeltaFee = uint24(deltaFee % minLpFee);

        uint24 bidLpFee = uint24(
            zeroForOne ? minLpFee + modDeltaFee : minLpFee - modDeltaFee
        ); // f+cA/f-cA

        uint24 offerLpFee = uint24(
            zeroForOne ? minLpFee - modDeltaFee : minLpFee + modDeltaFee
        ); // f-cA/f+cA

        // This can also made configurable and dynamic
        uint24 antiFragileFee = minLpFee / 2;

        // anti fragile fee
        // minimum fee should be atleast half of the pool fee
        if (bidLpFee < antiFragileFee) {
            bidLpFee = antiFragileFee;
        }

        if (offerLpFee < antiFragileFee) {
            offerLpFee = antiFragileFee;
        }

        // update last block & price to current
        feeConfig[key.toId()].lastblock = uint64(block.number);
        feeConfig[key.toId()].lastBlockSqrtX96 = currentSqrtPriceX96;

        poolLpFee[key.toId()][true] = bidLpFee;
        poolLpFee[key.toId()][false] = offerLpFee;

        return zeroForOne ? bidLpFee : offerLpFee;
    }

    function isNewBlock(PoolKey calldata key) internal view returns (bool) {
        return feeConfig[key.toId()].lastblock != block.number;
    }

    function _calculateDeltaChange(
        uint160 sqrtPriceX96A,
        uint160 sqrtPriceX96B
    ) internal pure returns (uint256 delta, uint256 relativeChange) {
        // Calculate absolute and relative change
        delta = sqrtPriceX96A > sqrtPriceX96B
            ? sqrtPriceX96A - sqrtPriceX96B
            : sqrtPriceX96B - sqrtPriceX96A;

        relativeChange = (delta * 1000000) / sqrtPriceX96B;
    }
}
