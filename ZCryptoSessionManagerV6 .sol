// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ZCrypto V6 会话密钥管理合约（草稿）
/// @notice 主钱包每次仅授权一把有效下注密钥，新授权立即替换旧密钥。
/// @dev 不管理资金、存取款、佣金或 GuessAccount 余额。
/// @dev 仅支持 EOA 钱包签名，不支持 ERC-1271 合约钱包。
contract ZCryptoSessionManagerV6 {
    error Unauthorized();
    error InvalidAddress();
    error InvalidSignature();
    error InvalidNonce();
    error InvalidDeadline();
    error InvalidExpiry();
    error NoActiveSession();
    error AllowanceExceeded();
    error AlreadyCommitted();
    error ZeroAmount();
    uint256 public constant DEFAULT_LIMIT = 10 ether; // 默认累计下注额度为 10 USDZ（18 位小数）
    uint64 public constant MAX_SESSION_DURATION = 1 days;
    bytes32 public constant REGISTER_TYPEHASH = keccak256(
        "RegisterSession(address user,address key,uint256 limit,uint64 expiry,uint256 nonce,uint64 deadline)"
    );
    bytes32 public constant REVOKE_TYPEHASH = keccak256(
        "RevokeSession(address user,uint256 nonce,uint64 deadline)"
    );
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("ZCrypto SessionManager");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant SECP256K1_HALF_N =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
    address public immutable guessEngine;
    struct Session {
        address key;
        uint64 expiry;
        uint256 limit;
        uint256 spent;
        uint256 generation;
    }
    mapping(address => Session) private _sessions;
    mapping(address => uint256) public nonces;

    // 每用户每轮只能累计扣除一次额度；更换密钥也不能重复提交。
    mapping(address => mapping(uint256 => bool)) public roundCommitted;
    event SessionRegistered(address indexed user, address indexed key, uint256 generation,
        uint256 limit, uint64 expiry);
    event SessionRevoked(address indexed user, uint256 generation);
    event AllowanceConsumed(address indexed user, address indexed key, uint256 indexed roundId,
        uint256 amount, uint256 spent);
    
    /// @notice 部署时绑定唯一竞猜合约，只有该合约能消费下注授权额度。
    constructor(address engine) {
        if (engine == address(0)) revert InvalidAddress();
        guessEngine = engine;
    }

    /// @notice 计算 EIP-712 域分隔符，绑定当前链 ID 和本合约地址，防止跨链及跨合约重放。
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)
        ));
    }

    /// @notice 将结构体哈希转换为 EIP-712 最终签名摘要，用于验证主钱包授权。
    function _typedDigest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @notice 通过 EIP-712 主钱包签名注册会话密钥，任何地址均可代提交。
    /// @dev 检查地址、时效、Nonce 和签名；新密钥立即替换旧密钥并重置本次额度。
    /// @param limit 传 0 使用默认 10 USDZ；其他值表示累计下注上限。
    function registerBySig(
        address user, address key, uint256 limit, uint64 expiry,
        uint256 nonce, uint64 deadline, bytes calldata signature
    ) external {
        if (user == address(0) || key == address(0) || user == key) revert InvalidAddress();
        if (block.timestamp > deadline) revert InvalidDeadline();
        if (expiry <= block.timestamp || uint256(expiry) > block.timestamp + MAX_SESSION_DURATION)
            revert InvalidExpiry();
        if (nonce != nonces[user]) revert InvalidNonce();
        bytes32 structHash = keccak256(abi.encode(
            REGISTER_TYPEHASH, user, key, limit, expiry, nonce, deadline
        ));
        if (_recover(_typedDigest(structHash), signature) != user) revert InvalidSignature();
        nonces[user] = nonce + 1;
        uint256 generation = _sessions[user].generation + 1;
        uint256 actualLimit = limit == 0 ? DEFAULT_LIMIT : limit;
        _sessions[user] = Session(key, expiry, actualLimit, 0, generation);
        emit SessionRegistered(user, key, generation, actualLimit, expiry);
    }

    /// @notice 主钱包直接撤销当前会话密钥，立即生效。
    /// @dev 同时推进授权 Nonce，防止旧授权签名再次生效。
    function revoke() external {
        // 同时使尚未执行的旧签名授权和撤销指令失效。
        nonces[msg.sender] += 1;
        _revoke(msg.sender);
    }

    /// @notice 主钱包签名撤销，允许任意地址代付 Gas 提交。
    /// @dev 验证撤销签名和 Nonce 后清空当前密钥。
    function revokeBySig(
        address user, uint256 nonce, uint64 deadline, bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert InvalidDeadline();
        if (nonce != nonces[user]) revert InvalidNonce();
        bytes32 structHash = keccak256(abi.encode(REVOKE_TYPEHASH, user, nonce, deadline));
        if (user == address(0) || _recover(_typedDigest(structHash), signature) != user)
            revert InvalidSignature();
        nonces[user] = nonce + 1;
        _revoke(user);
    }

    /// @notice 内部撤销指定用户当前会话密钥，清空密钥和有效期并发出撤销事件。
    function _revoke(address user) internal {
        Session storage s = _sessions[user];
        s.key = address(0);
        s.expiry = 0;
        emit SessionRevoked(user, s.generation);
    }

    /// @notice 查询用户当前会话信息，包括密钥、过期时间、额度、已消费额度及代次。
    function sessionOf(address user) external view returns (Session memory) {
        return _sessions[user];
    }

    /// @notice 检查指定密钥是否为该用户当前有效且未过期的会话密钥。
    function isActive(address user, address key) public view returns (bool) {
        Session storage s = _sessions[user];
        return key != address(0) && s.key == key && block.timestamp <= s.expiry;
    }

    /// @notice 验证竞猜合约构造的下注签名摘要是否由当前有效密钥签署。
    /// @dev 仅验证密钥身份与有效期，不验证下注 Nonce、轮次、价格或余额。
    function verifySessionSignature(
        address user, bytes32 betDigest, bytes calldata signature
    ) external view returns (bool) {
        address signer = _recover(betDigest, signature);
        return isActive(user, signer);
    }

    /// @notice 只有竞猜合约可以在核验下注后扣减累计授权额度。
    /// @dev 每用户每轮仅能消费一次；超出授权额度则拒绝。
    /// @dev 竞猜合约必须自行验证下注签名、资格和轮次状态。
    /// @dev 本函数不更新 GuessAccount，也不验证下注是否属于 BetRoot。
    function consumeForRound(address user, uint256 roundId, uint256 amount) external {
        if (msg.sender != guessEngine) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();
        if (roundCommitted[user][roundId]) revert AlreadyCommitted();
        Session storage s = _sessions[user];
        if (s.key == address(0) || block.timestamp > s.expiry) revert NoActiveSession();
        if (amount > s.limit - s.spent) revert AllowanceExceeded();
        s.spent += amount;
        roundCommitted[user][roundId] = true;
        emit AllowanceConsumed(user, s.key, roundId, amount, s.spent);
    }

    /// @notice 从 65 字节 ECDSA 签名恢复签名者地址，无效签名返回零地址。
    /// @dev 校验 v、r、s 并限制低 s 值，避免签名可塑性。
    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address signer) {
        // 标准签名由 r(32字节)、s(32字节)、v(1字节) 组成。
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        // 直接从 calldata 读取 r、s、v，减少内存复制。
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        // 只接受标准恢复标志 27 或 28。
        if (v != 27 && v != 28) return address(0);
        // 限制 s 在曲线阶数的一半以内，并拒绝零值 r/s。
        if (uint256(s) > SECP256K1_HALF_N || r == bytes32(0) || s == bytes32(0))
            return address(0);
        // 使用 EVM 原生指令恢复签名地址。
        signer = ecrecover(digest, v, r, s);
    }
}
