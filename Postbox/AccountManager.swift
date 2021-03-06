import Foundation
#if os(macOS)
    import SwiftSignalKitMac
#else
    import SwiftSignalKit
#endif

public struct AccountManagerModifier {
    public let getRecords: () -> [AccountRecord]
    public let updateRecord: (AccountRecordId, (AccountRecord?) -> (AccountRecord?)) -> Void
    public let getCurrentId: () -> AccountRecordId?
    public let setCurrentId: (AccountRecordId) -> Void
    public let createRecord: ([AccountRecordAttribute]) -> AccountRecordId
    public let getSharedData: (ValueBoxKey) -> AccountSharedData?
    public let updateSharedData: (ValueBoxKey, (AccountSharedData?) -> AccountSharedData?) -> Void
}

final class AccountManagerImpl {
    private let queue: Queue
    private let basePath: String
    private let temporarySessionId: Int64
    private let valueBox: ValueBox
    
    private var tables: [Table] = []
    
    private let metadataTable: AccountManagerMetadataTable
    private let recordTable: AccountManagerRecordTable
    let sharedDataTable: AccountManagerSharedDataTable
    
    private var currentRecordOperations: [AccountManagerRecordOperation] = []
    private var currentMetadataOperations: [AccountManagerMetadataOperation] = []
    
    private var currentUpdatedSharedDataKeys = Set<ValueBoxKey>()
    
    private var recordsViews = Bag<(MutableAccountRecordsView, ValuePipe<AccountRecordsView>)>()
    private var sharedDataViews = Bag<(MutableAccountSharedDataView, ValuePipe<AccountSharedDataView>)>()
    
    fileprivate init(queue: Queue, basePath: String, temporarySessionId: Int64) {
        self.queue = queue
        self.basePath = basePath
        self.temporarySessionId = temporarySessionId
        let _ = try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true, attributes: nil)
        self.valueBox = SqliteValueBox(basePath: basePath + "/db", queue: queue)
        
        self.metadataTable = AccountManagerMetadataTable(valueBox: self.valueBox, table: AccountManagerMetadataTable.tableSpec(0))
        self.recordTable = AccountManagerRecordTable(valueBox: self.valueBox, table: AccountManagerRecordTable.tableSpec(1))
        self.sharedDataTable = AccountManagerSharedDataTable(valueBox: self.valueBox, table: AccountManagerSharedDataTable.tableSpec(2))
        
        self.tables.append(self.metadataTable)
        self.tables.append(self.recordTable)
        self.tables.append(self.sharedDataTable)
    }
    
    deinit {
        assert(self.queue.isCurrent())
    }
    
    fileprivate func transaction<T>(_ f: @escaping (AccountManagerModifier) -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            self.queue.justDispatch {
                self.valueBox.begin()
                
                let transaction = AccountManagerModifier(getRecords: {
                    return self.recordTable.getRecords()
                }, updateRecord: { id, update in
                    let current = self.recordTable.getRecord(id: id)
                    let updated = update(current)
                    if updated != current {
                        self.recordTable.setRecord(id: id, record: updated, operations: &self.currentRecordOperations)
                    }
                }, getCurrentId: {
                    return self.metadataTable.getCurrentAccountId()
                }, setCurrentId: { id in
                    self.metadataTable.setCurrentAccountId(id, operations: &self.currentMetadataOperations)
                }, createRecord: { attributes in
                    let id = generateAccountRecordId()
                    let record = AccountRecord(id: id, attributes: attributes, temporarySessionId: nil)
                    self.recordTable.setRecord(id: id, record: record, operations: &self.currentRecordOperations)
                    return id
                }, getSharedData: { key in
                    return self.sharedDataTable.get(key: key)
                }, updateSharedData: { key, f in
                    let updated = f(self.sharedDataTable.get(key: key))
                    self.sharedDataTable.set(key: key, value: updated, updatedKeys: &self.currentUpdatedSharedDataKeys)
                })
                
                let result = f(transaction)
               
                self.beforeCommit()
                
                self.valueBox.commit()
                
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }
    
    private func beforeCommit() {
        if !self.currentRecordOperations.isEmpty || !self.currentMetadataOperations.isEmpty {
            for (view, pipe) in self.recordsViews.copyItems() {
                if view.replay(operations: self.currentRecordOperations, metadataOperations: self.currentMetadataOperations) {
                    pipe.putNext(AccountRecordsView(view))
                }
            }
        }
        
        if !self.currentUpdatedSharedDataKeys.isEmpty {
            for (view, pipe) in self.sharedDataViews.copyItems() {
                if view.replay(accountManagerImpl: self, updatedKeys: self.currentUpdatedSharedDataKeys) {
                    pipe.putNext(AccountSharedDataView(view))
                }
            }
        }
        
        self.currentRecordOperations.removeAll()
        self.currentMetadataOperations.removeAll()
        self.currentUpdatedSharedDataKeys.removeAll()
        
        for table in self.tables {
            table.beforeCommit()
        }
    }
    
    fileprivate func accountRecords() -> Signal<AccountRecordsView, NoError> {
        return self.transaction { transaction -> Signal<AccountRecordsView, NoError> in
            return self.accountRecordsInternal(transaction: transaction)
        }
        |> switchToLatest
    }
    
    fileprivate func sharedData(keys: Set<ValueBoxKey>) -> Signal<AccountSharedDataView, NoError> {
        return self.transaction { transaction -> Signal<AccountSharedDataView, NoError> in
            return self.sharedDataInternal(transaction: transaction, keys: keys)
        }
        |> switchToLatest
    }
    
    private func accountRecordsInternal(transaction: AccountManagerModifier) -> Signal<AccountRecordsView, NoError> {
        let mutableView = MutableAccountRecordsView(getRecords: {
            return self.recordTable.getRecords()
        }, currentId: self.metadataTable.getCurrentAccountId())
        let pipe = ValuePipe<AccountRecordsView>()
        let index = self.recordsViews.add((mutableView, pipe))
        
        let queue = self.queue
        return (.single(AccountRecordsView(mutableView))
        |> then(pipe.signal()))
        |> `catch` { _ -> Signal<AccountRecordsView, NoError> in
            return .complete()
        }
        |> afterDisposed { [weak self] in
            queue.async {
                if let strongSelf = self {
                    strongSelf.recordsViews.remove(index)
                }
            }
        }
    }
    
    private func sharedDataInternal(transaction: AccountManagerModifier, keys: Set<ValueBoxKey>) -> Signal<AccountSharedDataView, NoError> {
        let mutableView = MutableAccountSharedDataView(accountManagerImpl: self, keys: keys)
        let pipe = ValuePipe<AccountSharedDataView>()
        let index = self.sharedDataViews.add((mutableView, pipe))
        
        let queue = self.queue
        return (.single(AccountSharedDataView(mutableView))
        |> then(pipe.signal()))
        |> `catch` { _ -> Signal<AccountSharedDataView, NoError> in
            return .complete()
        }
        |> afterDisposed { [weak self] in
            queue.async {
                if let strongSelf = self {
                    strongSelf.sharedDataViews.remove(index)
                }
            }
        }
    }
    
    fileprivate func currentAccountId(allocateIfNotExists: Bool) -> Signal<AccountRecordId?, NoError> {
        return self.transaction { transaction -> Signal<AccountRecordId?, NoError> in
            let current = transaction.getCurrentId()
            let id: AccountRecordId
            if let current = current {
                id = current
            } else if allocateIfNotExists {
                id = generateAccountRecordId()
                transaction.setCurrentId(id)
                transaction.updateRecord(id, { _ in
                    return AccountRecord(id: id, attributes: [], temporarySessionId: nil)
                })
            } else {
                return .single(nil)
            }
            
            let signal = self.accountRecordsInternal(transaction: transaction)
            |> map { view -> AccountRecordId? in
                return view.currentRecord?.id
            }
            
            return signal
        }
        |> switchToLatest
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            return lhs == rhs
        })
    }
    
    func allocatedTemporaryAccountId() -> Signal<AccountRecordId, NoError> {
        let temporarySessionId = self.temporarySessionId
        return self.transaction { transaction -> Signal<AccountRecordId, NoError> in
            
            let id = generateAccountRecordId()
            transaction.updateRecord(id, { _ in
                return AccountRecord(id: id, attributes: [], temporarySessionId: temporarySessionId)
            })
            
            return .single(id)
        }
        |> switchToLatest
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            return lhs == rhs
        })
    }
}

public final class AccountManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountManagerImpl>
    public let temporarySessionId: Int64
    
    fileprivate init(basePath: String) {
        var temporarySessionId: Int64 = 0
        arc4random_buf(&temporarySessionId, 8)
        self.temporarySessionId = temporarySessionId
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return AccountManagerImpl(queue: queue, basePath: basePath, temporarySessionId: temporarySessionId)
        })
    }
    
    public func transaction<T>(_ f: @escaping (AccountManagerModifier) -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.transaction(f).start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func accountRecords() -> Signal<AccountRecordsView, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.accountRecords().start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func sharedData(keys: Set<ValueBoxKey>) -> Signal<AccountSharedDataView, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.sharedData(keys: keys).start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func currentAccountId(allocateIfNotExists: Bool) -> Signal<AccountRecordId?, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.currentAccountId(allocateIfNotExists: allocateIfNotExists).start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func allocatedTemporaryAccountId() -> Signal<AccountRecordId, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.allocatedTemporaryAccountId().start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
}

public func accountManager(basePath: String) -> Signal<AccountManager, NoError> {
    return Signal { subscriber in
        subscriber.putNext(AccountManager(basePath: basePath))
        subscriber.putCompletion()
        return EmptyDisposable
    }
}
