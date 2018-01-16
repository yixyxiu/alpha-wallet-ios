// Copyright SIX DAY LLC. All rights reserved.

import Foundation
import Result
import APIKit
import RealmSwift
import BigInt
import Moya
import TrustKeystore

enum TokenError: Error {
    case failedToFetch
}

protocol TokensDataStoreDelegate: class {
    func didUpdate(result: Result<TokensViewModel, TokenError>)
}

class TokensDataStore {

    private lazy var getBalanceCoordinator: GetBalanceCoordinator = {
        return GetBalanceCoordinator(web3: self.web3)
    }()
    private let provider = TrustProviderFactory.makeProvider()
    private lazy var ethToken = TokenObject(
        contract: "0x",
        name: config.server.name,
        symbol: config.server.symbol,
        decimals: config.server.decimals,
        value: "0",
        isCustom: false,
        type: .ether
    )

    let account: Wallet
    let config: Config
    let web3: Web3Swift
    weak var delegate: TokensDataStoreDelegate?
    let realm: Realm
    var tickers: [String: CoinTicker]? = .none
    var timer = Timer()
    //We should refresh prices every 5 minutes.
    let intervalToRefresh = 300.0
    var tokensModel: Subscribable<[TokenObject]> = Subscribable(nil)

    init(
        realm: Realm,
        account: Wallet,
        config: Config,
        web3: Web3Swift
    ) {
        self.account = account
        self.config = config
        self.web3 = web3
        self.realm = realm
        self.addEthToken()
        self.scheduledTimerForPricesUpdate()
    }
    private func addEthToken() {
        //Check if we have previos values.
        if objects.first(where: { $0.contract == ethToken.contract }) == nil {
            add(tokens: [ethToken])
        }
    }

    var objects: [TokenObject] {
        return realm.objects(TokenObject.self)
            .sorted(byKeyPath: "contract", ascending: true)
            .filter { !$0.contract.isEmpty }
    }

    var enabledObject: [TokenObject] {
        return realm.objects(TokenObject.self)
            .sorted(byKeyPath: "contract", ascending: true)
            .filter { !$0.isDisabled }
    }

    func update(tokens: [Token]) {
        realm.beginWrite()
        for token in tokens {
            let update: [String: Any] = [
                "owner": account.address.address,
                "chainID": config.chainID,
                "contract": token.address?.address ?? "",
                "name": token.name,
                "symbol": token.symbol,
                "decimals": token.decimals,
            ]
            realm.create(
                TokenObject.self,
                value: update,
                update: true
            )
        }
        try! realm.commitWrite()
    }

    func fetch() {
        let contracts = uniqueContracts()
        update(tokens: contracts)

        switch config.server {
        case .main:
            let request = GetTokensRequest(address: account.address.address)
            Session.send(request) { [weak self] result in
                guard let `self` = self else { return }
                switch result {
                case .success(let response):
                    self.update(tokens: response)
                    self.refreshBalance()
                case .failure: break
                }
            }
            updatePrices()
        case .classic, .kovan, .poa, .ropsten, .sokol:
            updatePrices()
            refreshBalance()
        }
    }

    func refreshBalance() {
        guard !enabledObject.isEmpty else {
            updateDelegate()
            return
        }
        let updateTokens = enabledObject.filter { $0.contract != ethToken.contract }
        var count = 0
        for tokenObject in updateTokens {
            guard let contract = Address(string: tokenObject.contract) else { return }
            getBalanceCoordinator.getBalance(for: account.address, contract: contract) { [weak self] result in
                guard let `self` = self else { return }
                switch result {
                case .success(let balance):
                    self.update(token: tokenObject, action: .value(balance))
                case .failure: break
                }
                count += 1
                if count == updateTokens.count {
                    //We should use prommis kit.
                    self.getBalanceCoordinator.getEthBalance(for: self.account.address) {  [weak self] result in
                        guard let `self` = self else { return }
                        switch result {
                        case .success(let balance):
                            self.update(token: self.objects.first (where: { $0.contract == self.ethToken.contract })!, action: .value(balance.value))
                            self.updateDelegate()
                        case .failure: break
                        }
                    }
                }
            }
        }
    }
    func updateDelegate() {
        tokensModel.value = enabledObject
        let tokensViewModel = TokensViewModel( tokens: enabledObject, tickers: tickers )
        delegate?.didUpdate(result: .success( tokensViewModel ))
    }

    func coinTicker(for token: TokenObject) -> CoinTicker? {
        return tickers?[token.contract]
    }

    func handleError(error: Error) {
        delegate?.didUpdate(result: .failure(TokenError.failedToFetch))
    }

    func addCustom(token: ERC20Token) {
        let newToken = TokenObject(
            contract: token.contract.address,
            symbol: token.symbol,
            decimals: token.decimals,
            value: "0",
            isCustom: true
        )
        add(tokens: [newToken])
    }

    func updatePrices() {
        let tokens = objects.map { TokenPrice(contract: $0.contract, symbol: $0.symbol) }
        let tokensPrice = TokensPrice(
            currency: config.currency.rawValue,
            tokens: tokens
        )
        provider.request(.prices(tokensPrice)) { [weak self] result in
            guard let `self` = self else { return }
            guard case .success(let response) = result else { return }
            do {
                let tickers = try response.map([CoinTicker].self, atKeyPath: "response", using: JSONDecoder())
                self.tickers = tickers.reduce([String: CoinTicker]()) { (dict, ticker) -> [String: CoinTicker] in
                    var dict = dict
                    dict[ticker.contract] = ticker
                    return dict
                }
                self.updateDelegate()
            } catch { }
        }
    }

    @discardableResult
    func add(tokens: [TokenObject]) -> [TokenObject] {
        realm.beginWrite()
        realm.add(tokens, update: true)
        try! realm.commitWrite()
        return tokens
    }

    func delete(tokens: [TokenObject]) {
        realm.beginWrite()
        realm.delete(tokens)
        try! realm.commitWrite()
    }

    enum TokenUpdate {
        case value(BigInt)
        case isDisabled(Bool)
    }

    func update(token: TokenObject, action: TokenUpdate) {
        try! realm.write {
            switch action {
            case .value(let value):
                token.value = value.description
            case .isDisabled(let value):
                token.isDisabled = value
            }
        }
    }

    func uniqueContracts() -> [Token] {
        let transactions = realm.objects(Transaction.self)
            .sorted(byKeyPath: "date", ascending: true)
            .filter { !$0.localizedOperations.isEmpty }

        let tokens: [Token] = transactions.flatMap { transaction in
            guard
                let operation = transaction.localizedOperations.first,
                let contract = operation.contract,
                let name = operation.name,
                let symbol = operation.symbol else { return nil }
            return Token(
                address: Address(string: contract),
                name: name,
                symbol: symbol,
                decimals: operation.decimals
            )
        }
        return tokens
    }
    private func scheduledTimerForPricesUpdate() {
        timer = Timer.scheduledTimer(withTimeInterval: intervalToRefresh, repeats: true) { [weak self] _ in
            self?.updatePrices()
        }
    }
    deinit {
        //We should make sure that timer is invalidate.
        timer.invalidate()
    }
}
