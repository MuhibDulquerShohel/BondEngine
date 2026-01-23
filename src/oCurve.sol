// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract oCurve is ERC20 {
    error OnlyBondingEngine();
    error NonTransferable();
    error AddressZero();

    address private bondingEngine;
    constructor(address _bondingEngine) ERC20("oCurve", "oCURVE") {
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

    function burn(address from, uint256 amount) external {
        if (msg.sender != bondingEngine) {
            revert OnlyBondingEngine();
        }
        _burn(from, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        super._update(from, to, value);
    }
}
