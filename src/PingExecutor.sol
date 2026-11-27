// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";

/// @title PingExecutor
/// @notice Measurement-only no-op callback target for the latency floor. It does no work beyond
///         recording, in an event, the timestamps it was given and the timestamp it was delivered
///         at, so an off-chain reader can split the delivery into its legs. Not part of trading.
contract PingExecutor is AbstractCallback {
    event PingDelivery(
        uint256 indexed seq,
        uint256 originBlockNumber,
        uint256 originTxHash,
        uint64 lasnaTs,
        uint64 destTs,
        uint256 gasLeftAtDelivery
    );

    constructor(IPayable callbackProxy_, address callbackSender_) AbstractCallback(callbackProxy_, callbackSender_) {}

    function onPing(
        address reactive_,
        uint256 seq_,
        uint256 originBlockNumber_,
        uint256 originTxHash_,
        uint64 lasnaTs_
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        emit PingDelivery(seq_, originBlockNumber_, originTxHash_, lasnaTs_, uint64(block.timestamp), gasleft());
    }

    /// @notice Pays any outstanding callback debt the proxy has recorded against this contract.
    function coverDebt() external {
        _coverDebt();
    }
}
