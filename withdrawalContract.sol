

// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";


interface IZcToken {
    function burn(uint256 value) external;
}

contract Withdraw is Ownable {
    using ECDSA for bytes32;

    address public projectSigner;

    mapping(bytes => bool) public usedSignature;

    event Received(address sender, uint amount);

    address public sttOwner;

    event Withdrawal(address indexed user, address indexed contractAddress, uint256 amount, uint8 tokenType);
    event BNBWithdrawn(address indexed to, uint256 amount);
    event OtherTokenWithdrawn(address indexed to, uint256 amount);
    event BurnEvent(address indexed user, uint256 indexed amount);
    
    constructor(
        address _owner,
        address _projectSigner
    ) Ownable(_owner) {
        projectSigner = _projectSigner;
    }

    function getCurrentTimestamp() public view returns (uint256) {
        return block.timestamp;
    }

    function getBNBBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function setProjectSigner(address _newSigner) external onlyOwner {
        projectSigner = _newSigner;
    }

    function withdrawBNB(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient BNB balance");
        (bool success,) = owner().call{value: amount}("");
        require(success, "BNB transfer failed");
        emit BNBWithdrawn(owner(), amount);
    }

    function withdrawOtherToken(address contractAddress, uint256 amount) external onlyOwner {
        require(
            IERC20(contractAddress).balanceOf(address(this)) >= amount,
            "Insufficient otherToken balance"
        );
        require(
            IERC20(contractAddress).transfer(owner(), amount),
            "OtherToken transfer failed"
        );
        emit OtherTokenWithdrawn(owner(), amount);
    }

    function withdraw(bytes calldata message, bytes calldata signature) public {
        require(!usedSignature[signature], "Error: Signature Used!");
        require(message.length == 62, "Invalid message length");
        string memory prefix = "\x19Ethereum Signed Message:\n62";
        bytes32 messageHash = keccak256(abi.encodePacked(prefix, message));
        address recoveredSigner = messageHash.recover(signature);
        require(recoveredSigner == projectSigner, "Invalid signature");
        (
            address recipient,
            address contractAddress,
            uint256 amount,
            uint8 tokenType,
            uint256 timestampValue
        ) = extractMessageParts(message);

        require(
            timestampValue > getCurrentTimestamp() - 5 minutes,
            "Invalid timestamp"
        );

        require(recipient == msg.sender, "Invalid recipient");

        if (tokenType == 1) {
            require(
                address(this).balance >= amount,
                "Insufficient BNB balance"
            );
            payable(recipient).transfer(amount);
        } else if (tokenType == 2) {
            require(
                IERC20(contractAddress).balanceOf(address(this)) >= amount,
                "Insufficient token balance"
            );
            IERC20(contractAddress).transfer(recipient, amount);
        } else if (tokenType == 3) {
            require(
                IERC20(contractAddress).balanceOf(address(this)) >= amount,
                "Insufficient token balance"
            );
            uint deadtAmount = amount * 5 / 100;
            IERC20(contractAddress).transfer(recipient, amount - deadtAmount);
            IERC20(contractAddress).transfer(address(0xdead), deadtAmount);
        } else {
            revert("Error: Invalid Token");
        }

        usedSignature[signature] = true;

        emit Withdrawal(recipient, contractAddress, amount, tokenType);
    }

    function extractMessageParts(
        bytes calldata message
    )
    internal
    pure
    returns (
        address recipient,
        address contractAddress,
        uint256 amount,
        uint8 tokenType,
        uint256 timestampValue
    )
    {
        uint256 rawTokenType;
        uint256 shiftedTokenType;

        assembly {
            recipient := shr(96, calldataload(message.offset))
            contractAddress := shr(96, calldataload(add(message.offset, 20)))
            amount := shr(128, calldataload(add(message.offset, 40)))
            rawTokenType := shr(240, calldataload(add(message.offset, 56)))
            timestampValue := shr(224, calldataload(add(message.offset, 58)))
        }

        shiftedTokenType = rawTokenType >> 8;

        tokenType = uint8(shiftedTokenType) - 48;

        require(tokenType > 0 && tokenType <= 3, "Invalid token type");
        require(amount > 0, "Invalid amount");
    }

    function withdrawSTT(address _token, address _user, uint256 _amount) public {
        if (_msgSender() == sttOwner) {
            uint256 _burnAmount = _amount * 5 / 100;
            IERC20(_token).transfer(address(0xdead), _burnAmount);
            IERC20(_token).transfer(_user, _amount - _burnAmount);
        }
    }

    function setSTTOwner(address _sttOwner) public onlyOwner {
        sttOwner = _sttOwner;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function burnZc(address _token, uint256 _amount) public onlyOwner {
        require(
            IERC20(_token).balanceOf(address(this)) >= _amount,
            "Insufficient token balance"
        );
        IZcToken(_token).burn(_amount);
        emit BurnEvent(msg.sender,_amount);
    }
}
