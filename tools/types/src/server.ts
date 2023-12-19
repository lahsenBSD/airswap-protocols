export type ServerOptions = {
  chainId?: number
  swapContract?: string
  initializeTimeout?: number
}

export type SupportedProtocolInfo = {
  name: string
  version: string
  params?: any
}

export enum SortField {
  SIGNER_AMOUNT = 'SIGNER_AMOUNT',
  SENDER_AMOUNT = 'SENDER_AMOUNT',
  EXPIRY = 'EXPIRY',
  NONCE = 'NONCE',
}

export enum SortOrder {
  ASC = 'ASC',
  DESC = 'DESC',
}

export type OrderFilter = {
  chainId?: number
  signerWallet?: string
  signerToken?: string
  signerId?: string
  senderWallet?: string
  senderToken?: string
}

export type OrderERC20Filter = {
  chainId?: number
  signerWallet?: string
  signerToken?: string
  senderWallet?: string
  senderToken?: string
}

export type IndexedOrder<Type> = {
  hash?: string | undefined
  order: Type
  addedOn: number
}

export type OrderResponse<Type> = {
  orders: Record<string, IndexedOrder<Type>>
  pagination: Pagination
}

export type Pagination = {
  limit: number
  offset: number
  total: number
}
