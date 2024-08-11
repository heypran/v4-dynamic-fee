// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

import {DynamicLPFeeLibrary} from "./DynamicFeeLibrary.sol";
import "forge-std/console.sol";

contract DirectionalFee is BaseHook {
    using PoolIdLibrary for PoolKey;
    using DynamicLPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    uint24 constant minLpFee = 3000;
    mapping(PoolId => uint160 lastBlockSqrtX96) public poolLastBlockSqrtX96;
    mapping(PoolId => mapping(bool zeroForOne => uint24 lpfee))
        public poolLpFee;
    mapping(PoolId => uint256 lastBlock) public poolLastBlock;

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
                beforeInitialize: true, //
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, //
                afterSwap: true, //
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

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes calldata
    ) external override returns (bytes4) {
        // Implement your logic here
        if (!key.fee.isDynamicFee()) {
            revert DynamicFeeNotEnabled();
        }

        poolLastBlock[key.toId()] = block.number;
        poolLastBlockSqrtX96[key.toId()] = sqrtPriceX96;

        poolLpFee[key.toId()][true] = minLpFee;
        poolLpFee[key.toId()][false] = minLpFee;

        return BaseHook.beforeInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        console.log("Before Swap");
        uint24 lpFee = _getFee(key, params.zeroForOne);
        console.log("new lpFee");
        console.log(lpFee);
        console.log("Block");
        console.log(block.number);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            lpFee
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        _updateFeeParams(key);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _updateFeeParams(PoolKey calldata key) internal {
        (uint160 newSqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        console.log("newSqrtPriceX96");
        console.log(newSqrtPriceX96);
        poolLastBlockSqrtX96[key.toId()] = newSqrtPriceX96;
    }

    function _getFee(
        PoolKey calldata key,
        bool zeroForOne
    ) internal returns (uint24 lpFee) {
        console.log("########## getFee");
        console.log("Block");
        console.log(block.number);
        // console.logBool(isNewBlock(key));
        if (!isNewBlock(key)) {
            return poolLpFee[key.toId()][zeroForOne];
        }
        console.log("########## newBlock");
        console.log(block.number);

        // update last block to current
        poolLastBlock[key.toId()] = block.number;

        // do the math
        (uint160 currentSqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint160 lastBlockSqrtPriceX96 = poolLastBlockSqrtX96[key.toId()];

        if (currentSqrtPriceX96 == lastBlockSqrtPriceX96) {
            poolLpFee[key.toId()][zeroForOne] = minLpFee;
            poolLpFee[key.toId()][!zeroForOne] = minLpFee;
            return minLpFee;
        }

        console.log("currentSqrtPriceX96");
        console.log(currentSqrtPriceX96);
        console.log(lastBlockSqrtPriceX96);

        (, uint256 relativeChange) = _calculateDeltaChange(
            currentSqrtPriceX96,
            lastBlockSqrtPriceX96
        );

        console.log("priceChangeDelta");
        console.log(block.number);
        console.log(relativeChange);

        uint256 deltaFee = (75 * relativeChange) / 100;

        console.log(minLpFee + deltaFee);
        console.log(minLpFee - deltaFee);

        uint24 bidLpFee = uint24(
            zeroForOne ? minLpFee + deltaFee : minLpFee - deltaFee
        ); //f+cA/f-cA

        uint24 offerLpFee = uint24(
            zeroForOne ? minLpFee - deltaFee : minLpFee + deltaFee
        ); // f-cA/f+cA

        require(bidLpFee >= 0);
        require(offerLpFee >= 0);

        poolLpFee[key.toId()][zeroForOne] = bidLpFee;
        poolLpFee[key.toId()][!zeroForOne] = offerLpFee;

        return zeroForOne ? bidLpFee : offerLpFee;
    }

    function isNewBlock(PoolKey calldata key) internal returns (bool) {
        uint256 lastBlockNumber = poolLastBlock[key.toId()];
        if (lastBlockNumber == block.number) {
            return false;
        }
        return true;
    }

    // TODO optimize import from existing libs
    uint256 constant Q96 = 2 ** 96;
    uint256 constant Q192 = Q96 * Q96;

    function _sqrtPriceX96ToPrice(
        uint160 sqrtPriceX96
    ) private pure returns (uint256) {
        // Compute price P from sqrtPriceX96
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / Q192;
    }

    // TODO optimize
    function _calculateDeltaChange(
        uint160 sqrtPriceX96A,
        uint160 sqrtPriceX96B
    ) private pure returns (uint256 delta, uint256 relativeChange) {
        uint256 priceA = _sqrtPriceX96ToPrice(sqrtPriceX96A);
        uint256 priceB = _sqrtPriceX96ToPrice(sqrtPriceX96B);

        // Calculate absolute and relative change
        delta = priceA > priceB ? priceA - priceB : priceB - priceA;
        relativeChange = priceA < priceB
            ? (delta * 100) / priceA
            : (delta * 100) / priceB;
    }
}
