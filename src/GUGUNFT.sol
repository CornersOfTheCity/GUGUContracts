// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GUGUNFT
 * @notice ERC-721 NFT with 3 rarity tiers: Founder, Pro, Basic
 *         Users can mint with ETH; authorized minters (MysteryBox) can mint for free.
 */
contract GUGUNFT is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable, ReentrancyGuard {
    enum Rarity { Founder, Pro, Basic }

    /// @notice 每个 tokenId 对应的稀有度
    mapping(uint256 => Rarity) private _tokenRarity;

    /// @notice 每种稀有度已铸造数量
    mapping(Rarity => uint256) public totalSupplyByRarity;

    /// @notice 每种稀有度最大供应量
    mapping(Rarity => uint256) public maxSupplyByRarity;

    /// @notice 每种稀有度的铸造价格 (ETH)
    mapping(Rarity => uint256) public mintPriceByRarity;

    /// @notice 授权 Minter (盲盒合约等)
    mapping(address => bool) public minters;

    /// @dev 下一个 tokenId
    uint256 private _nextTokenId;

    /// @notice baseURI
    string private _baseTokenURI;

    // ── Events ──
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event NFTMinted(address indexed to, uint256 indexed tokenId, Rarity rarity);

    // ── Errors ──
    error NotMinter(address caller);
    error ExceedsMaxSupply(Rarity rarity);
    error InsufficientPayment(uint256 required, uint256 sent);
    error WithdrawFailed();

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter(msg.sender);
        _;
    }

    constructor() ERC721("GUGU NFT", "GUGUNFT") Ownable(msg.sender) {
        // 最大供应量
        maxSupplyByRarity[Rarity.Founder] = 100;
        maxSupplyByRarity[Rarity.Pro] = 500;
        maxSupplyByRarity[Rarity.Basic] = 2000;

        // 铸造价格
        mintPriceByRarity[Rarity.Founder] = 0.5 ether;
        mintPriceByRarity[Rarity.Pro] = 0.1 ether;
        mintPriceByRarity[Rarity.Basic] = 0.02 ether;

        _nextTokenId = 1;
    }

    // ═══════════════════════════════════════════
    //                公开铸造
    // ═══════════════════════════════════════════

    /// @notice 用户付 ETH 铸造指定稀有度的 NFT
    function mintPublic(Rarity rarity) external payable nonReentrant {
        uint256 price = mintPriceByRarity[rarity];
        if (msg.value < price) revert InsufficientPayment(price, msg.value);
        if (totalSupplyByRarity[rarity] >= maxSupplyByRarity[rarity]) {
            revert ExceedsMaxSupply(rarity);
        }

        uint256 tokenId = _mintInternal(msg.sender, rarity);

        // 退还多余的 ETH
        if (msg.value > price) {
            (bool success,) = payable(msg.sender).call{value: msg.value - price}("");
            require(success, "Refund failed");
        }

        emit NFTMinted(msg.sender, tokenId, rarity);
    }

    // ═══════════════════════════════════════════
    //             授权铸造 (盲盒等)
    // ═══════════════════════════════════════════

    /// @notice 授权 Minter 铸造 (不需要付 ETH)
    function mint(address to, Rarity rarity) external onlyMinter returns (uint256) {
        if (totalSupplyByRarity[rarity] >= maxSupplyByRarity[rarity]) {
            revert ExceedsMaxSupply(rarity);
        }
        uint256 tokenId = _mintInternal(to, rarity);
        emit NFTMinted(to, tokenId, rarity);
        return tokenId;
    }

    // ═══════════════════════════════════════════
    //              Minter 管理
    // ═══════════════════════════════════════════

    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    // ═══════════════════════════════════════════
    //                查询
    // ═══════════════════════════════════════════

    /// @notice 查询 NFT 稀有度
    function getRarity(uint256 tokenId) external view returns (Rarity) {
        _requireOwned(tokenId); // 确保 token 存在
        return _tokenRarity[tokenId];
    }

    /// @notice 总供应量 (所有稀有度)
    function maxTotalSupply() external view returns (uint256) {
        return maxSupplyByRarity[Rarity.Founder]
            + maxSupplyByRarity[Rarity.Pro]
            + maxSupplyByRarity[Rarity.Basic];
    }

    // ═══════════════════════════════════════════
    //              Owner 管理
    // ═══════════════════════════════════════════

    function setBaseURI(string calldata baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }

    function withdraw() external onlyOwner {
        (bool success,) = payable(owner()).call{value: address(this).balance}("");
        if (!success) revert WithdrawFailed();
    }

    // ═══════════════════════════════════════════
    //              内部方法
    // ═══════════════════════════════════════════

    function _mintInternal(address to, Rarity rarity) internal returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _tokenRarity[tokenId] = rarity;
        totalSupplyByRarity[rarity]++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    // ═══════════════════════════════════════════
    //        Override required by Solidity
    // ═══════════════════════════════════════════

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
