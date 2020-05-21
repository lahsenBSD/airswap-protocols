pragma solidity ^0.5.10;
pragma experimental ABIEncoderV2;

import "@airswap/types/contracts/Types.sol";
import "openzeppelin-solidity/contracts/introspection/ERC165Checker.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC721/IERC721.sol";
import "@airswap/tokens/contracts/interfaces/IERC1155.sol";
import "@airswap/swap/contracts/interfaces/ISwap.sol";
import "@airswap/transfers/contracts/TransferHandlerRegistry.sol";
import "@airswap/tokens/contracts/interfaces/IWETH.sol";
import "@airswap/tokens/contracts/interfaces/IAdaptedKittyERC721.sol";
import "@airswap/delegate/contracts/interfaces/IDelegateV2.sol";
import "@airswap/types/contracts/BytesManipulator.sol";


/**
 * @title Validator: Helper contract to Swap protocol
 * @notice contains several helper methods that check whether
 * a Swap.order is well-formed and counterparty criteria is met
 */
contract Validator {
  using ERC165Checker for address;
  using BytesManipulator for bytes;

  bytes internal constant DOM_NAME = "SWAP";
  bytes internal constant DOM_VERSION = "2";

  bytes4 internal constant ERC1155_INTERFACE_ID = 0xd9b67a26;
  bytes4 internal constant ERC721_INTERFACE_ID = 0x80ac58cd;
  bytes4 internal constant ERC20_INTERFACE_ID = 0x36372b07;
  bytes4 internal constant CK_INTERFACE_ID = 0x9a20483d;

  IWETH public wethContract;

  // size of fixed array that holds max returning error messages
  uint256 internal constant MAX_ERROR_COUNT = 25;
  // size of fixed array that holds errors from delegate contract checks
  uint256 internal constant MAX_DELEGATE_ERROR_COUNT = 10;

  /**
   * @notice Contract Constructor
   * @param validatorWethContract address
   */
  constructor(address validatorWethContract) public {
    wethContract = IWETH(validatorWethContract);
  }

  /**
   * @notice If order is going through wrapper to a delegate
   * @param order Types.Order
   * @param delegate IDelegateV2
   * @param wrapper address
   * @return uint256 errorCount if any
   * @return bytes32[] memory array of error messages
   */
  function checkWrappedDelegate(
    Types.Order calldata order,
    IDelegateV2 delegate,
    address wrapper
  ) external view returns (uint256, bytes32[] memory) {
    address swap = order.signature.validator;
    (uint256 errorCount, bytes32[] memory errors) = this.coreSwapChecks(order);
    (uint256 delegateErrorCount, bytes32[] memory delegateErrors) = this
      .coreDelegateChecks(order, delegate);

    if (delegateErrorCount > 0) {
      // copies over errors from coreDelegateChecks
      for (uint256 i = 0; i < delegateErrorCount; i++) {
        errors[i + errorCount] = delegateErrors[i];
      }
      errorCount += delegateErrorCount;
    }

    // Check valid token registry handler for sender
    if (order.sender.kind == ERC20_INTERFACE_ID) {
      // Check the order sender balance and allowance
      if (!this.hasBalance(order.sender)) {
        errors[errorCount] = "SENDER_BALANCE_LOW";
        errorCount++;
      }

      // Check their approval
      if (!this.isApproved(order.sender, swap)) {
        errors[errorCount] = "SENDER_ALLOWANCE_LOW";
        errorCount++;
      }
    }

    // Check valid token registry handler for signer
    if (order.signer.kind == ERC20_INTERFACE_ID) {
      if (order.signer.token != address(wethContract)) {
        // Check the order signer token balance
        if (!this.hasBalance(order.signer)) {
          errors[errorCount] = "SIGNER_BALANCE_LOW";
          errorCount++;
        }
      } else {
        if ((order.signer.wallet).balance < order.signer.data.getUint256(0)) {
          errors[errorCount] = "SIGNER_ETHER_LOW";
          errorCount++;
        }
      }

      // Check their approval
      if (!this.isApproved(order.signer, swap)) {
        errors[errorCount] = "SIGNER_ALLOWANCE_LOW";
        errorCount++;
      }
    }

    // ensure that sender wallet if receiving weth has approved
    // the wrapper to transfer weth and deliver eth to the sender
    if (order.sender.token == address(wethContract)) {
      uint256 allowance = wethContract.allowance(order.signer.wallet, wrapper);
      if (allowance < order.sender.data.getUint256(0)) {
        errors[errorCount] = "SIGNER_WRAPPER_ALLOWANCE_LOW";
        errorCount++;
      }
    }

    return (errorCount, errors);
  }

  /**
   * @notice If order is going through wrapper to swap
   * @param order Types.Order
   * @param fromAddress address
   * @param wrapper address
   * @return uint256 errorCount if any
   * @return bytes32[] memory array of error messages
   */
  function checkWrappedSwap(
    Types.Order calldata order,
    address fromAddress,
    address wrapper
  ) external view returns (uint256, bytes32[] memory) {
    address swap = order.signature.validator;

    (uint256 errorCount, bytes32[] memory errors) = this.coreSwapChecks(order);

    if (order.sender.wallet != fromAddress) {
      errors[errorCount] = "MSG_SENDER_MUST_BE_ORDER_SENDER";
      errorCount++;
    }

    // ensure that sender has approved wrapper contract on swap
    if (
      swap != address(0x0) &&
      !ISwap(swap).senderAuthorizations(order.sender.wallet, wrapper)
    ) {
      errors[errorCount] = "SENDER_UNAUTHORIZED";
      errorCount++;
    }

    // signature must be filled in order to use the Wrapper
    if (order.signature.v == 0) {
      errors[errorCount] = "SIGNATURE_MUST_BE_SENT";
      errorCount++;
    }

    // if sender has WETH token, ensure sufficient ETH balance
    if (order.sender.token == address(wethContract)) {
      if ((order.sender.wallet).balance < order.sender.data.getUint256(0)) {
        errors[errorCount] = "SENDER_ETHER_LOW";
        errorCount++;
      }
    }

    // ensure that sender wallet if receiving weth has approved
    // the wrapper to transfer weth and deliver eth to the sender
    if (order.signer.token == address(wethContract)) {
      uint256 allowance = wethContract.allowance(order.sender.wallet, wrapper);
      if (allowance < order.signer.data.getUint256(0)) {
        errors[errorCount] = "SENDER_WRAPPER_ALLOWANCE_LOW";
        errorCount++;
      }
    }

    // Check valid token registry handler for sender
    if (hasValidKind(order.sender.kind, swap)) {
      // Check the order sender
      if (order.sender.wallet != address(0)) {
        // The sender was specified
        // Check if sender kind interface can correctly check balance
        if (!hasValidInterface(order.sender.token, order.sender.kind)) {
          errors[errorCount] = "SENDER_TOKEN_KIND_MISMATCH";
          errorCount++;
        } else {
          // Check the order sender token balance when sender is not WETH
          if (order.sender.token != address(wethContract)) {
            //do the balance check
            if (!this.hasBalance(order.sender)) {
              errors[errorCount] = "SENDER_BALANCE_LOW";
              errorCount++;
            }
          }

          // Check their approval
          if (!this.isApproved(order.sender, swap)) {
            errors[errorCount] = "SENDER_ALLOWANCE_LOW";
            errorCount++;
          }
        }
      }
    } else {
      errors[errorCount] = "SENDER_TOKEN_KIND_UNKNOWN";
      errorCount++;
    }

    // Check valid token registry handler for signer
    if (hasValidKind(order.signer.kind, swap)) {
      // Check if signer kind interface can correctly check balance
      if (!hasValidInterface(order.signer.token, order.signer.kind)) {
        errors[errorCount] = "SIGNER_TOKEN_KIND_MISMATCH";
        errorCount++;
      } else {
        // Check the order signer token balance
        if (!this.hasBalance(order.signer)) {
          errors[errorCount] = "SIGNER_BALANCE_LOW";
          errorCount++;
        }

        // Check their approval
        if (!this.isApproved(order.signer, swap)) {
          errors[errorCount] = "SIGNER_ALLOWANCE_LOW";
          errorCount++;
        }
      }
    } else {
      errors[errorCount] = "SIGNER_TOKEN_KIND_UNKNOWN";
      errorCount++;
    }

    return (errorCount, errors);
  }

  /**
   * @notice Takes in an order and outputs any
   * errors that Swap would revert on
   * @param order Types.Order Order to settle
   * @return uint256 errorCount if any
   * @return bytes32[] memory array of error messages
   */
  function checkSwap(Types.Order calldata order)
    external
    view
    returns (uint256, bytes32[] memory)
  {
    address swap = order.signature.validator;
    (uint256 errorCount, bytes32[] memory errors) = this.coreSwapChecks(order);

    // Check valid token registry handler for sender
    if (hasValidKind(order.sender.kind, swap)) {
      // Check the order sender
      if (order.sender.wallet != address(0)) {
        // The sender was specified
        // Check if sender kind interface can correctly check balance
        if (!hasValidInterface(order.sender.token, order.sender.kind)) {
          errors[errorCount] = "SENDER_TOKEN_KIND_MISMATCH";
          errorCount++;
        } else {
          // Check the order sender token balance
          //do the balance check
          if (!this.hasBalance(order.sender)) {
            errors[errorCount] = "SENDER_BALANCE_LOW";
            errorCount++;
          }

          // Check their approval
          if (!this.isApproved(order.sender, swap)) {
            errors[errorCount] = "SENDER_ALLOWANCE_LOW";
            errorCount++;
          }
        }
      }
    } else {
      errors[errorCount] = "SENDER_TOKEN_KIND_UNKNOWN";
      errorCount++;
    }

    // Check valid token registry handler for signer
    if (hasValidKind(order.signer.kind, swap)) {
      // Check if signer kind interface can correctly check balance
      if (!hasValidInterface(order.signer.token, order.signer.kind)) {
        errors[errorCount] = "SIGNER_TOKEN_KIND_MISMATCH";
        errorCount++;
      } else {
        // Check the order signer token balance
        if (!this.hasBalance(order.signer)) {
          errors[errorCount] = "SIGNER_BALANCE_LOW";
          errorCount++;
        }

        // Check their approval
        if (!this.isApproved(order.signer, swap)) {
          errors[errorCount] = "SIGNER_ALLOWANCE_LOW";
          errorCount++;
        }
      }
    } else {
      errors[errorCount] = "SIGNER_TOKEN_KIND_UNKNOWN";
      errorCount++;
    }

    return (errorCount, errors);
  }

  /**
   * @notice If order is going through delegate via provideOrder
   * ensure necessary checks are set
   * @param order Types.Order
   * @param delegate IDelegateV2
   * @return uint256 errorCount if any
   * @return bytes32[] memory array of error messages
   */
  function checkDelegate(Types.Order calldata order, IDelegateV2 delegate)
    external
    view
    returns (uint256, bytes32[] memory)
  {
    (uint256 errorCount, bytes32[] memory errors) = this.checkSwap(order);
    (uint256 delegateErrorCount, bytes32[] memory delegateErrors) = this
      .coreDelegateChecks(order, delegate);

    if (delegateErrorCount > 0) {
      // copies over errors from coreDelegateChecks
      for (uint256 i = 0; i < delegateErrorCount; i++) {
        errors[i + errorCount] = delegateErrors[i];
      }
      errorCount += delegateErrorCount;
    }

    return (errorCount, errors);
  }

  /**
   * @notice Condenses swap specific checks while excluding
   * token balance or approval checks
   * @param order Types.Order
   * @return uint256 errorCount if any
   * @return bytes32[] memory array of error messages
   */
  function coreSwapChecks(Types.Order calldata order)
    external
    view
    returns (uint256, bytes32[] memory)
  {
    address swap = order.signature.validator;
    bytes32 domainSeparator = Types.hashDomain(DOM_NAME, DOM_VERSION, swap);

    // max size of the number of errors
    bytes32[] memory errors = new bytes32[](MAX_ERROR_COUNT);
    uint256 errorCount;

    // Check self transfer
    if (order.signer.wallet == order.sender.wallet) {
      errors[errorCount] = "SELF_TRANSFER_INVALID";
      errorCount++;
    }

    // Check expiry
    if (order.expiry < block.timestamp) {
      errors[errorCount] = "ORDER_EXPIRED";
      errorCount++;
    }

    if (swap != address(0x0)) {
      ISwap swapContract = ISwap(swap);
      if (
        swapContract.signerNonceStatus(order.signer.wallet, order.nonce) != 0x00
      ) {
        errors[errorCount] = "ORDER_TAKEN_OR_CANCELLED";
        errorCount++;
      }

      if (order.nonce < swapContract.signerMinimumNonce(order.signer.wallet)) {
        errors[errorCount] = "NONCE_TOO_LOW";
        errorCount++;
      }

      if (order.signature.signatory != order.signer.wallet) {
        if (
          !swapContract.signerAuthorizations(
            order.signer.wallet,
            order.signature.signatory
          )
        ) {
          errors[errorCount] = "SIGNER_UNAUTHORIZED";
          errorCount++;
        }
      }
    } else {
      errors[errorCount] = "VALIDATOR_INVALID";
      errorCount++;
    }

    // check if ERC721 or ERC20 only amount or id set for sender
    if (
      order.sender.kind == ERC20_INTERFACE_ID ||
      order.sender.kind == ERC721_INTERFACE_ID ||
      order.sender.kind == CK_INTERFACE_ID
    ) {
      if (order.sender.data.length != 32) {
        errors[errorCount] = "DATA_MUST_BE_32_BYTES";
        errorCount++;
      }
    }

    if (
      order.sender.kind == ERC1155_INTERFACE_ID &&
      order.sender.data.length != 64
    ) {
      errors[errorCount] = "DATA_MUST_BE_64_BYTES";
      errorCount++;
    }

    // check if ERC721 or ERC20 only amount or id set for signer
    if (
      order.signer.kind == ERC20_INTERFACE_ID ||
      order.signer.kind == ERC721_INTERFACE_ID ||
      order.signer.kind == CK_INTERFACE_ID
    ) {
      if (order.signer.data.length != 32) {
        errors[errorCount] = "DATA_MUST_BE_32_BYTES";
        errorCount++;
      }
    }

    if (
      order.signer.kind == ERC1155_INTERFACE_ID &&
      order.signer.data.length != 64
    ) {
      errors[errorCount] = "DATA_MUST_BE_64_BYTES";
      errorCount++;
    }

    if (!this.isValid(order, domainSeparator)) {
      errors[errorCount] = "SIGNATURE_INVALID";
      errorCount++;
    }

    return (errorCount, errors);
  }

  /**
   * @notice Condenses Delegate specific checks
   * and excludes swap or balance related checks
   * @param order Types.Order
   * @param delegate IDelegateV2 Delegate to interface with
   * @return uint256 errorCount if any
   * @return bytes32[] memory array of error messages
   */
  function coreDelegateChecks(Types.Order calldata order, IDelegateV2 delegate)
    external
    view
    returns (uint256, bytes32[] memory)
  {
    uint256 maxSender;
    uint256 maxSigner;

    (maxSender, maxSigner) = delegate.getMaxQuote(
      order.sender.token,
      order.signer.token
    );

    uint256 firstRuleID = delegate.firstRuleID(
      order.sender.token,
      order.signer.token
    );

    bytes32[] memory errors = new bytes32[](MAX_DELEGATE_ERROR_COUNT);
    uint256 errorCount;
    address swap = order.signature.validator;
    // signature must be filled in order to use the Delegate
    if (order.signature.v == 0) {
      errors[errorCount] = "SIGNATURE_MUST_BE_SENT";
      errorCount++;
    }

    // check that the sender.wallet == tradewallet
    if (order.sender.wallet != delegate.tradeWallet()) {
      errors[errorCount] = "SENDER_WALLET_INVALID";
      errorCount++;
    }

    // ensure signer kind is ERC20
    if (order.signer.kind != ERC20_INTERFACE_ID) {
      errors[errorCount] = "SIGNER_KIND_MUST_BE_ERC20";
      errorCount++;
    }

    // ensure sender kind is ERC20
    if (order.sender.kind != ERC20_INTERFACE_ID) {
      errors[errorCount] = "SENDER_KIND_MUST_BE_ERC20";
      errorCount++;
    }

    // ensure that token pair is active
    if (firstRuleID == 0) {
      errors[errorCount] = "TOKEN_PAIR_INACTIVE";
      errorCount++;
    }

    // check the delegate will trade this much
    if (order.sender.data.getUint256(0) > maxSender) {
      errors[errorCount] = "ORDER_AMOUNT_EXCEEDS_MAX";
      errorCount++;
    }

    // get the signer's amount according to delegate pricing
    uint256 signerAmount = delegate.getSignerSideQuote(
      order.sender.data.getUint256(0),
      order.sender.token,
      order.signer.token
    );

    // check the order is paying enough
    if (order.signer.data.getUint256(0) < signerAmount) {
      errors[errorCount] = "PRICE_INVALID";
      errorCount++;
    }

    // ensure that tradeWallet has approved delegate contract on swap
    if (
      swap != address(0x0) &&
      !ISwap(swap).senderAuthorizations(order.sender.wallet, address(delegate))
    ) {
      errors[errorCount] = "SENDER_UNAUTHORIZED";
      errorCount++;
    }

    return (errorCount, errors);
  }

  /**
   * @notice Check a party has enough balance to swap
   * for supported token types
   * @param party Types.Party party to check balance for
   * @return bool whether party has enough balance
   */
  function hasBalance(Types.Party calldata party) external view returns (bool) {
    uint256 firstParameter = party.data.getUint256(0);
    if (party.kind == ERC721_INTERFACE_ID || party.kind == CK_INTERFACE_ID) {
      address owner = IERC721(party.token).ownerOf(firstParameter);
      return (owner == party.wallet);
    } else if (party.kind == ERC1155_INTERFACE_ID) {
      uint256 balance = IERC1155(party.token).balanceOf(
        party.wallet,
        firstParameter
      );
      return (balance >= party.data.getUint256(32));
    } else {
      uint256 balance = IERC20(party.token).balanceOf(party.wallet);
      return (balance >= firstParameter);
    }
  }

  /**
   * @notice Check a party has enough allowance to swap
   * for ERC721, CryptoKitties, and ERC20 tokens
   * @param party Types.Party party to check allowance for
   * @param swap address Swap address
   * @return bool whether party has sufficient allowance
   */
  function isApproved(Types.Party calldata party, address swap)
    external
    view
    returns (bool)
  {
    uint256 parameter = party.data.getUint256(0);
    if (party.kind == ERC721_INTERFACE_ID) {
      address approved = IERC721(party.token).getApproved(parameter);
      return (swap == approved);
    } else if (party.kind == CK_INTERFACE_ID) {
      address approved = IAdaptedKittyERC721(party.token).kittyIndexToApproved(
        parameter
      );
      return (swap == approved);
    } else if (party.kind == ERC1155_INTERFACE_ID) {
      return IERC1155(party.token).isApprovedForAll(party.wallet, swap);
    } else {
      uint256 allowance = IERC20(party.token).allowance(party.wallet, swap);
      return (allowance >= parameter);
    }
  }

  /**
   * @notice Check order signature is valid
   * @param order Types.Order Order to validate
   * @param domainSeparator bytes32 Domain identifier used in signatures (EIP-712)
   * @return bool True if order has a valid signature
   */
  function isValid(Types.Order calldata order, bytes32 domainSeparator)
    external
    pure
    returns (bool)
  {
    if (order.signature.v == 0) {
      return true;
    }
    if (order.signature.version == bytes1(0x01)) {
      return
        order.signature.signatory ==
        ecrecover(
          Types.hashOrder(order, domainSeparator),
          order.signature.v,
          order.signature.r,
          order.signature.s
        );
    }
    if (order.signature.version == bytes1(0x45)) {
      return
        order.signature.signatory ==
        ecrecover(
          keccak256(
            abi.encodePacked(
              "\x19Ethereum Signed Message:\n32",
              Types.hashOrder(order, domainSeparator)
            )
          ),
          order.signature.v,
          order.signature.r,
          order.signature.s
        );
    }
    return false;
  }

  /**
   * @notice Checks if kind is found in
   * Swap's Token Registry
   * @param kind bytes4 token type to search for
   * @param swap address Swap contract address
   * @return bool whether kind inserted is valid
   */
  function hasValidKind(bytes4 kind, address swap)
    internal
    view
    returns (bool)
  {
    if (swap != address(0x0)) {
      TransferHandlerRegistry tokenRegistry = ISwap(swap).registry();
      return (address(tokenRegistry.transferHandlers(kind)) != address(0));
    } else {
      return false;
    }
  }

  /**
   * @notice Checks token has valid interface
   * @param tokenAddress address potential valid interface
   * @return bool whether address has valid interface
   */
  function hasValidInterface(address tokenAddress, bytes4 interfaceID)
    internal
    view
    returns (bool)
  {
    // ERC20s don't normally implement this method
    if (interfaceID != ERC20_INTERFACE_ID) {
      return (tokenAddress._supportsInterface(interfaceID));
    }
    return true;
  }
}
