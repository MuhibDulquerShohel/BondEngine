//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICurve is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function decimals() external view returns (uint8);
}

interface BondingCurveErrors {
    error AddressZero();
    error InvalidBps();
    error PriceZero();
    error AmountZero();
    error ExceedsLimit();
    error MissCalculation();
}

contract BondingCurve is Ownable, ReentrancyGuard, BondingCurveErrors {
    ICurve private Curve;
    ICurve private OCurve;
    ICurve private USDC;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private liquidityBps;

    address private liquidityVault;
    address private treasury;

    uint256 private priceUSDC;
    uint256 private decimalsUSDC;
    uint256 private bondDuration;

    bool private isLimitedBond;
    uint256 private maxBondPerWallet;

    mapping(address => BondInfo) private userToBonds;

    struct BondInfo {
        address user;
        uint256 lastClaimedAt;
        uint256 fullClaimAvailableAt;
        uint256 oCurveBurned;
        uint256 usdcIn;
        uint256 curveClaimed;
        uint256 curveRemainToClaim;
        uint256 totalOCurve;
    }

    event Bonded(
        address indexed user,
        uint256 usdcIn,
        uint256 curveOut,
        uint256 priceUSDC
    );

    event VaultsUpdated(
        address liquidityVault,
        address treasury,
        uint256 liquidityBps
    );
    event PriceUpdated(uint256 priceUSDC);
    event TokenContractsUpdated(address curve, address ocurve, address usdc);
    event CurveClaimed(address indexed user, uint256 curveOut);

    constructor() Ownable(msg.sender) {}

    function getCurve() external view returns (address) {
        return address(Curve);
    }

    function getOCurve() external view returns (address) {
        return address(OCurve);
    }

    function getUSDC() external view returns (address) {
        return address(USDC);
    }

    function getLiquidityBps() external view returns (uint256) {
        return liquidityBps;
    }

    function getLiquidityVault() external view returns (address) {
        return liquidityVault;
    }

    function getTreasury() external view returns (address) {
        return treasury;
    }

    function getPriceUSDC() external view returns (uint256) {
        return priceUSDC;
    }

    function getDecimalsUSDC() external view returns (uint256) {
        return decimalsUSDC;
    }

    function getBpsDenominator() external pure returns (uint256) {
        return BPS_DENOMINATOR;
    }

    function getBondDuration() external view returns (uint256) {
        return bondDuration;
    }

    function getUserBondInfo(
        address user
    ) external view returns (BondInfo memory) {
        return userToBonds[user];
    }

    function getIsLimitedBond() external view returns (bool) {
        return isLimitedBond;
    }

    function getMaxBondPerWallet() external view returns (uint256) {
        return maxBondPerWallet;
    }

    function enableLimitBond(
        bool _isLimitedBond,
        uint256 _maxBondPerWallet
    ) external onlyOwner {
        isLimitedBond = _isLimitedBond;
        maxBondPerWallet = _maxBondPerWallet;
    }

    function setVaults(
        address _liquidityVault,
        address _treasury,
        uint256 _liquidityBps
    ) external onlyOwner {
        if (_liquidityVault == address(0) || _treasury == address(0)) {
            revert AddressZero();
        }

        if (_liquidityBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        liquidityVault = _liquidityVault;
        treasury = _treasury;
        liquidityBps = _liquidityBps;
        emit VaultsUpdated(_liquidityVault, treasury, liquidityBps);
    }

    function setPriceUSDC(uint256 _priceUSDC) external onlyOwner {
        if (_priceUSDC == 0) {
            revert PriceZero();
        }
        priceUSDC = _priceUSDC;
        emit PriceUpdated(_priceUSDC);
    }

    function setBondDuration(uint256 _bondDuration) external onlyOwner {
        bondDuration = _bondDuration;
    }

    function setTokenContracts(
        address _curve,
        address _ocurve,
        address _usdc
    ) external onlyOwner {
        if (
            _curve == address(0) || _ocurve == address(0) || _usdc == address(0)
        ) {
            revert AddressZero();
        }
        Curve = ICurve(_curve);
        OCurve = ICurve(_ocurve);
        USDC = ICurve(_usdc);
        decimalsUSDC = USDC.decimals();
        emit TokenContractsUpdated(_curve, _ocurve, _usdc);
    }

    function witdrawStuckUSDC(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            revert AddressZero();
        }
        USDC.transfer(to, amount);
    }

    function bond(uint256 usdcIn) external nonReentrant {
        if (usdcIn <= 0) {
            revert AmountZero();
        }
        uint256 tokenOutput;

        USDC.transferFrom(msg.sender, address(this), usdcIn);

        uint256 toLiquidity = (usdcIn * liquidityBps) / BPS_DENOMINATOR;
        uint256 toTreasury = usdcIn - toLiquidity;

        USDC.transfer(liquidityVault, toLiquidity);
        USDC.transfer(treasury, toTreasury);
        uint256 usdcIn18D = usdcIn * 10 ** (18 - decimalsUSDC);
        uint256 usdcAmount18 = (usdcIn18D * priceUSDC) / 1e18;
        tokenOutput += usdcAmount18;

        if (tokenOutput <= 0) {
            revert AmountZero();
        }
        uint256 amountToMint = tokenOutput;
        tokenOutput = 0;
        BondInfo storage bondInfo = userToBonds[msg.sender];
        bondInfo.usdcIn += usdcIn;
        if (isLimitedBond) {
            if (bondInfo.usdcIn > maxBondPerWallet) {
                revert ExceedsLimit();
            }
        }
        if (bondInfo.user == address(0)) {
            bondInfo.user = msg.sender;
            bondInfo.lastClaimedAt = block.timestamp;
        } else if (
            block.timestamp > bondInfo.lastClaimedAt &&
            bondInfo.lastClaimedAt != 0
        ) {
            uint256 vestedAmount;
            if (block.timestamp > bondInfo.fullClaimAvailableAt) {
                vestedAmount = bondInfo.curveRemainToClaim;
            } else {
                vestedAmount =
                    (bondInfo.totalOCurve *
                        (block.timestamp - bondInfo.lastClaimedAt)) /
                    bondDuration;
            }
            bondInfo.lastClaimedAt = block.timestamp;

            bondInfo.oCurveBurned += vestedAmount;
            bondInfo.curveClaimed += vestedAmount;
            bondInfo.curveRemainToClaim -= vestedAmount;
            OCurve.burn(msg.sender, vestedAmount);
            Curve.mint(msg.sender, vestedAmount);
        }

        bondInfo.fullClaimAvailableAt = block.timestamp + bondDuration;

        bondInfo.totalOCurve += amountToMint;
        bondInfo.curveRemainToClaim += amountToMint;

        OCurve.mint(msg.sender, amountToMint);

        emit Bonded(msg.sender, usdcIn, amountToMint, priceUSDC);
    }

    function claimCurve() external nonReentrant {
        BondInfo storage bondInfo = userToBonds[msg.sender];
        if (bondInfo.user == address(0)) {
            revert AddressZero();
        }
        if (bondInfo.curveRemainToClaim == 0) {
            revert AmountZero();
        }
        uint256 vestedAmount;
        if (block.timestamp > bondInfo.fullClaimAvailableAt) {
            vestedAmount = bondInfo.curveRemainToClaim;
        } else {
            vestedAmount =
                (bondInfo.totalOCurve *
                    (block.timestamp - bondInfo.lastClaimedAt)) /
                bondDuration;
        }
        bondInfo.lastClaimedAt = block.timestamp;
        if (bondInfo.curveRemainToClaim < vestedAmount) {
            revert MissCalculation();
        }
        bondInfo.oCurveBurned += vestedAmount;
        bondInfo.curveClaimed += vestedAmount;
        bondInfo.curveRemainToClaim -= vestedAmount;
        OCurve.burn(msg.sender, vestedAmount);
        Curve.mint(msg.sender, vestedAmount);

        emit CurveClaimed(msg.sender, vestedAmount);
    }
}
