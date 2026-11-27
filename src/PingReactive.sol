// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title PingReactive
/// @notice Measurement-only no-op floor. This is NOT part of the trading path. It subscribes to
///         plain ERC20 `Transfer` events on one origin chain and requests a trivial, fixed-gas
///         callback to a destination no-op executor. It exists to measure the Reactive Network's
///         delivery latency for a callback whose payload does no work, so the arb callback's
///         delivery time can be compared against a floor that contains no contract computation.
/// @dev No cooldown, no threshold, no state math: one trigger -> one callback request.
contract PingReactive is AbstractReactive {
    /// @dev keccak256("Transfer(address,address,uint256)")
    uint256 private constant TRANSFER_TOPIC0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint64 private constant CALLBACK_GAS_LIMIT = 200_000;

    uint256 public immutable originChainId;
    uint256 public immutable destChainId;
    address public immutable originToken;
    address public owner;

    address public target;
    uint256 public seq;

    event PingDetected(
        uint256 indexed seq,
        uint256 originChainId,
        uint256 originBlockNumber,
        uint256 originTxHash,
        uint64 lasnaTs,
        uint256 destChainId
    );
    event TargetSet(address indexed target);

    error OnlyOwner(address caller_);

    constructor(uint256 originChainId_, address originToken_, uint256 destChainId_) payable {
        require(originChainId_ != 0 && destChainId_ != 0 && originChainId_ != destChainId_, "BAD_CHAINS");
        require(originToken_ != address(0), "BAD_TOKEN");

        owner = msg.sender;
        originChainId = originChainId_;
        destChainId = destChainId_;
        originToken = originToken_;

        SYSTEM.subscribe(originChainId_, originToken_, TRANSFER_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setTarget(address target_) external {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        target = target_;
        emit TargetSet(target_);
    }

    function react(LogRecord calldata log_) external override onlySystem {
        if (log_.chainId != originChainId || log_.contractAddress != originToken || log_.topic0 != TRANSFER_TOPIC0) {
            return;
        }
        if (target == address(0)) return;

        uint256 s = ++seq;
        uint64 lasnaTs = uint64(block.timestamp);

        // First payload arg is the address(0) placeholder the proxy replaces with this contract.
        bytes memory payload = abi.encodeWithSignature(
            "onPing(address,uint256,uint256,uint256,uint64)", address(0), s, log_.blockNumber, log_.txHash, lasnaTs
        );

        try SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: target, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        ) {}
            catch {}

        emit PingDetected(s, originChainId, log_.blockNumber, log_.txHash, lasnaTs, destChainId);
    }

    /// @notice Pays outstanding callback debt to the system contract from this contract's RNK balance.
    function coverDebt() external {
        _coverDebt();
    }
}
