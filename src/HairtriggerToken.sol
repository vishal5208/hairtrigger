// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title HairtriggerToken
/// @notice Testnet ERC20 used as the non-WETH side of the Hairtrigger pools.
/// @dev Supply is minted by the owner (deployer) to seed both chains. This token has no
///      economic value; it exists so the experiment is fully fundable from a faucet and
///      does not depend on acquiring testnet USDC on Unichain Sepolia.
contract HairtriggerToken is ERC20, Ownable {
    constructor(address initialOwner_) ERC20("Hairtrigger", "HTRG") Ownable(initialOwner_) {}

    function mint(address to_, uint256 amount_) external onlyOwner {
        _mint(to_, amount_);
    }
}
