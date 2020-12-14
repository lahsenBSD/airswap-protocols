/*
  Copyright 2020 Swap Holdings Ltd.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/cryptography/MerkleProof.sol";

/**
 * @title Pool: Claim Tokens Based on a Pricing Function
 */
contract Pool is Ownable, Pausable {
  using SafeMath for uint256;

  // Higher the scale, lower the output for a claim
  uint256 public _scale;

  // Max percentage for a claim with infinite score
  uint256 public _max;

  // Mapping of tree root to boolean to enable claims
  mapping(bytes32 => bool) public _roots;

  // Mapping of tree root to account to boolean to mark as claimed
  mapping(bytes32 => mapping(address => bool)) public _claimed;

  /**
   * @notice Events
   */
  event Enable(bytes32 root);
  event Single(bytes32 root, address account, address token, uint256 amount);
  event Bulk(bytes32[] roots, address account, address token, uint256 amount);

  /**
   * @notice Structs
   */
  struct Claim {
    bytes32 root;
    uint256 score;
    bytes32[] proof;
  }

  /**
   * @notice Constructor
   * @param scale_ uint256
   * @param max_ uint256
   */
  constructor(uint256 scale_, uint256 max_) public {
    _scale = scale_;
    _max = max_;
  }

  /**
   * @notice Enables claims on the merkle tree of a set of scores
   * @param root bytes32
   */
  function enable(bytes32 root) external onlyOwner {
    require(_roots[root] == false, "ROOT_EXISTS");
    _roots[root] = true;
    emit Enable(root);
  }

  /**
   * @notice Single claim of tokens to be transferred to msg.sender
   * @param root bytes32
   * @param score uint256
   * @param proof bytes32[]
   * @param token address
   */
  function single(
    bytes32 root,
    uint256 score,
    bytes32[] memory proof,
    address token
  ) public {
    require(_roots[root], "ROOT_NOT_ENABLED");
    require(!_claimed[root][msg.sender], "CLAIM_INVALID");
    require(verify(msg.sender, root, score, proof), "PROOF_INVALID");
    _claimed[root][msg.sender] = true;

    uint256 amount = getOutput(score, token);
    IERC20(token).transfer(msg.sender, amount);
    emit Single(root, msg.sender, token, amount);
  }

  /**
   * @notice Bulk claim of tokens to be transferred to msg.sender
   * @param claims Claim[]
   * @param token address
   */
  function bulk(Claim[] memory claims, address token) public {
    require(claims.length > 0, "NO_CLAIMS_PROVIDED");
    uint256 totalScore = 0;
    bytes32[] memory roots = new bytes32[](claims.length);
    Claim memory claim;
    for (uint256 i = 0; i < claims.length; i++) {
      claim = claims[i];
      require(_roots[claim.root], "ROOT_NOT_ENABLED");
      require(!_claimed[claim.root][msg.sender], "CLAIM_INVALID");
      require(
        verify(msg.sender, claim.root, claim.score, claim.proof),
        "PROOF_INVALID"
      );
      totalScore = totalScore + claim.score;
      _claimed[claim.root][msg.sender] = true;
    }
    uint256 amount = getOutput(totalScore, token);
    IERC20(token).transfer(msg.sender, amount);
    emit Bulk(roots, msg.sender, token, amount);
  }

  /**
   * @notice Get output amount for an input score
   * @param score uint256
   * @param token address
   */
  function getOutput(uint256 score, address token)
    public
    view
    returns (uint256 amount)
  {
    return
      (_max *
        ((score * IERC20(token).balanceOf(address(this))) /
          ((10**_scale) + score))) / 100;
  }

  /**
   * @notice Verify a claim proof
   * @param participant address
   * @param root bytes32
   * @param score uint256
   * @param proof bytes32[]
   */
  function verify(
    address participant,
    bytes32 root,
    uint256 score,
    bytes32[] memory proof
  ) public view returns (bool valid) {
    bytes32 leaf = keccak256(abi.encodePacked(participant, score));
    return MerkleProof.verify(proof, root, leaf);
  }
}
