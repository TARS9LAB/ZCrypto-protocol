

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * ZC NFT 合约
 * 
 * 两种 NFT：
 *   tokenId 1~99999      → 钢铁英雄 NFT（白名单完成7000ZC销售）
 *   tokenId 100000~       → 财富自由 NFT（散户买10ZC激活）
 * 
 * PHP 后端调用 mint 发放，每种每人只能一个
 */
contract ZCNFT is ERC721, Ownable {

    // NFT 类型
    uint256 public constant TYPE_IRON_MAN = 1;        // 钢铁英雄
    uint256 public constant TYPE_FINANCIAL_FREEDOM = 2; // 财富自由

    // 各类型的自增 ID
    uint256 public ironManNextId = 1;          // 钢铁英雄从 1 开始
    uint256 public financialFreedomNextId = 100000; // 财富自由从 100000 开始

    // 防重复：用户 → NFT类型 → 是否已持有
    mapping(address => mapping(uint256 => bool)) public hasMinted;

    // tokenId → NFT 类型
    mapping(uint256 => uint256) public tokenType;

    // 铸造权限（PHP 后端用的钱包地址）
    mapping(address => bool) public minters;

    // 元数据 URI
    string public ironManURI;
    string public financialFreedomURI;

    event NFTMinted(address indexed to, uint256 indexed tokenId, uint256 nftType);

    modifier onlyMinter() {
        require(minters[msg.sender] || msg.sender == owner(), "not minter");
        _;
    }

    constructor(
        address _owner,
        string memory _ironManURI,
        string memory _financialFreedomURI
    ) ERC721("ZC NFT", "ZCNFT") Ownable(_owner) {
        ironManURI = _ironManURI;
        financialFreedomURI = _financialFreedomURI;
    }

    /**
     * 铸造钢铁英雄 NFT
     * 条件：白名单完成 7000 ZC 销售
     * 调用者：PHP 后端（minter 角色）
     */
    function mintIronMan(address to) external onlyMinter returns (uint256) {
        require(!hasMinted[to][TYPE_IRON_MAN], "already minted");

        uint256 tokenId = ironManNextId++;
        hasMinted[to][TYPE_IRON_MAN] = true;
        tokenType[tokenId] = TYPE_IRON_MAN;

        _safeMint(to, tokenId);
        emit NFTMinted(to, tokenId, TYPE_IRON_MAN);
        return tokenId;
    }

    /**
     * 铸造财富自由 NFT
     * 条件：散户买 >= 10 ZC 激活
     * 调用者：PHP 后端（minter 角色）
     */
    function mintFinancialFreedom(address to) external onlyMinter returns (uint256) {
        require(!hasMinted[to][TYPE_FINANCIAL_FREEDOM], "already minted");

        uint256 tokenId = financialFreedomNextId++;
        hasMinted[to][TYPE_FINANCIAL_FREEDOM] = true;
        tokenType[tokenId] = TYPE_FINANCIAL_FREEDOM;

        _safeMint(to, tokenId);
        emit NFTMinted(to, tokenId, TYPE_FINANCIAL_FREEDOM);
        return tokenId;
    }

    /**
     * 查询用户是否持有某类型 NFT
     */
    function hasNFT(address user, uint256 nftType) external view returns (bool) {
        return hasMinted[user][nftType];
    }

    /**
     * tokenURI：根据类型返回不同的元数据
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(ownerOf(tokenId) != address(0), "nonexistent token");

        if (tokenType[tokenId] == TYPE_IRON_MAN) {
            return ironManURI;
        } else {
            return financialFreedomURI;
        }
    }

    // ============ 管理函数 ============

    function setMinter(address _minter, bool _enabled) external onlyOwner {
        minters[_minter] = _enabled;
    }

    function setURIs(string memory _ironManURI, string memory _financialFreedomURI) external onlyOwner {
        ironManURI = _ironManURI;
        financialFreedomURI = _financialFreedomURI;
    }
}
