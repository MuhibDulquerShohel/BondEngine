// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Curve is ERC20 {
    error OnlyBondingEngine();
    error AddressZero();

    address private bondingEngine;
    constructor(address _bondingEngine) ERC20("Curve", "CURVE") {
        if (_bondingEngine == address(0)) {
            revert AddressZero();
        }
        bondingEngine = _bondingEngine;
    }

    function getBondingEngine() external view returns (address) {
        return bondingEngine;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != bondingEngine) {
            revert OnlyBondingEngine();
        }
        _mint(to, amount);
    }
}
