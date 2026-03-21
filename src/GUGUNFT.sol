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

    /// @notice Rarity associated with each tokenId
    mapping(uint256 => Rarity) private _tokenRarity;

    /// @notice Total minted count per rarity
    mapping(Rarity => uint256) public totalSupplyByRarity;


    /// @notice Mint price per rarity (in ETH)
    mapping(Rarity => uint256) public mintPriceByRarity;

    /// @notice Authorized minters (e.g. MysteryBox contract)
    mapping(address => bool) public minters;

    /// @dev Next tokenId to mint
    uint256 private _nextTokenId;

    /// @notice Base token URI
    string private _baseTokenURI;

    // ── Events ──
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event NFTMinted(address indexed to, uint256 indexed tokenId, Rarity rarity);

    // ── Errors ──
    error NotMinter(address caller);

    error InsufficientPayment(uint256 required, uint256 sent);
    error WithdrawFailed();
    error InvalidPrice();

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter(msg.sender);
        _;
    }

    constructor(address initialOwner) ERC721("GUGU NFT", "GUGUNFT") Ownable(initialOwner) {
        // Mint price (~$5 / ~$50 / ~$500 at ETH ≈ $2000)
        mintPriceByRarity[Rarity.Founder] = 0.25 ether;
        mintPriceByRarity[Rarity.Pro] = 0.025 ether;
        mintPriceByRarity[Rarity.Basic] = 0.0025 ether;

        _nextTokenId = 1;
    }

    // ═══════════════════════════════════════════
    //              Public Minting
    // ═══════════════════════════════════════════

    /// @notice Mint an NFT of the specified rarity by paying ETH
    function mintPublic(Rarity rarity) external payable nonReentrant {
        uint256 price = mintPriceByRarity[rarity];
        if (msg.value < price) revert InsufficientPayment(price, msg.value);

        uint256 tokenId = _mintInternal(msg.sender, rarity);

        // Refund excess ETH
        if (msg.value > price) {
            (bool success,) = payable(msg.sender).call{value: msg.value - price}("");
            require(success, "Refund failed");
        }

        emit NFTMinted(msg.sender, tokenId, rarity);
    }

    // ═══════════════════════════════════════════
    //         Authorized Minting (MysteryBox, etc.)
    // ═══════════════════════════════════════════

    /// @notice Authorized minter mint (no ETH required)
    function mint(address to, Rarity rarity) external onlyMinter returns (uint256) {
        uint256 tokenId = _mintInternal(to, rarity);
        emit NFTMinted(to, tokenId, rarity);
        return tokenId;
    }

    /// @notice Authorized minter batch mint (same rarity, same recipient)
    /// @param to       Recipient address
    /// @param rarity   NFT rarity tier
    /// @param quantity Number of NFTs to mint (max 50)
    function mintBatch(address to, Rarity rarity, uint256 quantity) external onlyMinter {
        require(quantity > 0 && quantity <= 50, "Invalid quantity");
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = _mintInternal(to, rarity);
            emit NFTMinted(to, tokenId, rarity);
        }
    }

    // ═══════════════════════════════════════════
    //              Minter Management
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
    //                Queries
    // ═══════════════════════════════════════════

    /// @notice Get the rarity of an NFT
    function getRarity(uint256 tokenId) external view returns (Rarity) {
        _requireOwned(tokenId); // Ensure the token exists
        return _tokenRarity[tokenId];
    }



    // ═══════════════════════════════════════════
    //              Owner Management
    // ═══════════════════════════════════════════

    function setBaseURI(string calldata baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }

    /// @notice Update the mint price for a specific rarity
    /// @param rarity NFT rarity tier (0=Founder, 1=Pro, 2=Basic)
    /// @param price  New price in wei (e.g. 0.25 ether)
    function setMintPrice(Rarity rarity, uint256 price) external onlyOwner {
        if (price == 0) revert InvalidPrice();
        mintPriceByRarity[rarity] = price;
    }

    function withdraw() external onlyOwner {
        (bool success,) = payable(owner()).call{value: address(this).balance}("");
        if (!success) revert WithdrawFailed();
    }

    // ═══════════════════════════════════════════
    //              Internal Methods
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
