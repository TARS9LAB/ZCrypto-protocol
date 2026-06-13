
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ZCPrivateSale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDT;
    address public treasury;      // 国库 96%
    address public commission;    // 佣金池 4%

    uint256 public treasuryRate = 9600;   // 96%
    uint256 public commissionRate = 400;  // 4%
    uint256 public minAmount = 7.5 ether; // 最低7.5U（10个ZC）

    event PrivateSalePurchase(
        address indexed buyer,
        uint256 usdtAmount,
        uint256 toTreasury,
        uint256 toCommission
    );

    constructor(
        address _usdt,
        address _treasury,
        address _commission,
        address _owner
    ) Ownable(_owner) {
        USDT = IERC20(_usdt);
        treasury = _treasury;
        commission = _commission;
    }

    function buyZC(uint256 usdtAmount) external nonReentrant {
        require(usdtAmount >= minAmount, "min 7.5U");

        // 收 USDT
        USDT.safeTransferFrom(msg.sender, address(this), usdtAmount);

        // 拆分
        uint256 toTreasury = (usdtAmount * treasuryRate) / 10000;
        uint256 toCommission = usdtAmount - toTreasury;

        // 转账
        USDT.safeTransfer(treasury, toTreasury);
        USDT.safeTransfer(commission, toCommission);

        // 发事件 → PHP 监听后记账
        emit PrivateSalePurchase(msg.sender, usdtAmount, toTreasury, toCommission);
    }

    // 管理员可调整地址
    function setAddresses(address _treasury, address _commission) external onlyOwner {
        require(_treasury != address(0) && _commission != address(0), "zero");
        treasury = _treasury;
        commission = _commission;
    }
}
