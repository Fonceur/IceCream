//
//  PublicDatabaseManager.swift
//  IceCream
//
//  Created by caiyue on 2019/4/22.
//

#if os(macOS)
import Cocoa
#else
import UIKit
#endif

import CloudKit

final class PublicDatabaseManager: DatabaseManager {
    
    let container: CKContainer
    let database: CKDatabase
    
    let syncObjects: [Syncable]
    let savePolicy: CKModifyRecordsOperation.RecordSavePolicy

    public var isCustomZoneCreated: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: IceCreamKey.hasCustomPublicZoneCreatedKey.value) as? Bool else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: IceCreamKey.hasCustomPublicZoneCreatedKey.value)
        }
    }

    public var zoneChangesToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: IceCreamKey.zonePublicChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: IceCreamKey.zonePublicChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: IceCreamKey.zonePublicChangesTokenKey.value)
        }
    }

    init(objects: [Syncable], container: CKContainer, savePolicy: CKModifyRecordsOperation.RecordSavePolicy) {
        self.syncObjects = objects
        self.container = container
        self.database = container.publicCloudDatabase
        self.savePolicy = savePolicy
    }
    
    func fetchChangesInDatabase(_ callback: ((Error?) -> Void)?) {
        syncObjects.forEach { [weak self] syncObject in
            let predicate = NSPredicate(value: true)
            let query = CKQuery(recordType: syncObject.recordType, predicate: predicate)
            let queryOperation = CKQueryOperation(query: query)
            self?.excuteQueryOperation(queryOperation: queryOperation, on: syncObject, callback: callback)
        }
    }
    
    func createCustomZonesIfAllowed() {
        
    }
    
    func createDatabaseSubscriptionIfHaveNot() {
        syncObjects.forEach { createSubscriptionInPublicDatabase(on: $0) }
    }
    
    func startObservingTermination() {
        #if os(iOS) || os(tvOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: UIApplication.willTerminateNotification, object: nil)
        
        #elseif os(macOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: NSApplication.willTerminateNotification, object: nil)
        
        #endif
    }
    
    func registerLocalDatabase() {
        syncObjects.forEach { object in
            DispatchQueue.main.async {
                object.registerLocalDatabase()
            }
        }
    }
    
    // MARK: - Private Methods
    private func excuteQueryOperation(queryOperation: CKQueryOperation,on syncObject: Syncable, callback: ((Error?) -> Void)? = nil) {
        queryOperation.recordFetchedBlock = { record in
            syncObject.add(record: record)
        }
        
        queryOperation.queryCompletionBlock = { [weak self] cursor, error in
            guard let self = self else { return }
            if let cursor = cursor {
                let subsequentQueryOperation = CKQueryOperation(cursor: cursor)
                self.excuteQueryOperation(queryOperation: subsequentQueryOperation, on: syncObject, callback: callback)
                return
            }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                DispatchQueue.main.async {
                    callback?(nil)
                }
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    self.excuteQueryOperation(queryOperation: queryOperation, on: syncObject, callback: callback)
                })
            default:
                DispatchQueue.main.async {
                    callback?(error)
                }
                break
            }
        }
        
        database.add(queryOperation)
    }
    
    private func createSubscriptionInPublicDatabase(on syncObject: Syncable) {
        #if os(iOS) || os(tvOS) || os(macOS)
        let predict = NSPredicate(value: true)
        let subscription = CKQuerySubscription(recordType: syncObject.recordType, predicate: predict, subscriptionID: IceCreamSubscription.cloudKitPublicDatabaseSubscriptionID.id, options: [CKQuerySubscription.Options.firesOnRecordCreation, CKQuerySubscription.Options.firesOnRecordUpdate, CKQuerySubscription.Options.firesOnRecordDeletion])
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // Silent Push
        
        subscription.notificationInfo = notificationInfo
        
        let createOp = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        createOp.modifySubscriptionsCompletionBlock = { _, _, _ in
            
        }
        createOp.qualityOfService = .utility
        database.add(createOp)
        #endif
    }
    
    @objc func cleanUp() {
        for syncObject in syncObjects {
            syncObject.cleanUp()
        }
    }
}
