//
//  PrivateDatabaseManager.swift
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

final class PrivateDatabaseManager: DatabaseManager {
    let container: CKContainer
    let database: CKDatabase
    
    let syncObjects: [Syncable]
    let savePolicy: CKModifyRecordsOperation.RecordSavePolicy

    public var isCustomZoneCreated: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: IceCreamKey.hasCustomZoneCreatedKey.value) as? Bool else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: IceCreamKey.hasCustomZoneCreatedKey.value)
        }
    }

    public var zoneChangesToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: IceCreamKey.zoneChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: IceCreamKey.zoneChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: IceCreamKey.zoneChangesTokenKey.value)
        }
    }

    public init(objects: [Syncable], container: CKContainer, savePolicy: CKModifyRecordsOperation.RecordSavePolicy) {
        self.syncObjects = objects
        self.container = container
        self.database = container.privateCloudDatabase
        self.savePolicy = savePolicy
    }
    
    func fetchChangesInDatabase(_ callback: ((Error?) -> Void)?) {
        let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)
        
        /// Only update the changeToken when fetch process completes
        changesOperation.changeTokenUpdatedBlock = { [weak self] newToken in
            self?.databaseChangeToken = newToken
        }
        
        changesOperation.fetchDatabaseChangesCompletionBlock = {
            [weak self]
            newToken, _, error in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.databaseChangeToken = newToken
                // Fetch the changes in zone level
                self.fetchChangesInZones(callback)
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    self.fetchChangesInDatabase(callback)
                })
            case .recoverableError(let reason, _):
                switch reason {
                case .changeTokenExpired:
                    /// The previousServerChangeToken value is too old and the client must re-sync from scratch
                    self.databaseChangeToken = nil
                    self.fetchChangesInDatabase(callback)
                default:
                    callback?(error)
                    return
                }
            default:
                callback?(error)
                return
            }
        }
        
        database.add(changesOperation)
    }
    
    func createCustomZonesIfAllowed() {
        if isCustomZoneCreated {
            return
        }

        let zonesToCreate = [CKRecordZone(zoneID: zoneIds[0])]

        let modifyOp = CKModifyRecordZonesOperation(recordZonesToSave: zonesToCreate, recordZoneIDsToDelete: nil)
        modifyOp.modifyRecordZonesCompletionBlock = { [weak self](_, _, error) in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.isCustomZoneCreated = true
                
                self.syncObjects.forEach { object in
                    // As we register local database in the first step, we have to force push local objects which
                    // have not been caught to CloudKit to make data in sync
                    DispatchQueue.main.async {
                        object.pushLocalObjectsToCloudKit()
                    }
                }
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    self.createCustomZonesIfAllowed()
                })
            default:
                return
            }
        }

        database.add(modifyOp)
    }

    func createDatabaseSubscriptionIfHaveNot() {
        #if os(iOS) || os(tvOS) || os(macOS)
        guard !subscriptionIsLocallyCached else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: IceCreamSubscription.cloudKitPrivateDatabaseSubscriptionID.id)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // Silent Push
        
        subscription.notificationInfo = notificationInfo
        
        let createOp = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        createOp.modifySubscriptionsCompletionBlock = { _, _, error in
            guard error == nil else { return }
            self.subscriptionIsLocallyCached = true
        }
        createOp.qualityOfService = .utility
        database.add(createOp)
        #endif
    }
    
    func startObservingTermination() {
        #if os(iOS) || os(tvOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: UIApplication.willTerminateNotification, object: nil)
        
        #elseif os(macOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: NSApplication.willTerminateNotification, object: nil)
        
        #endif
    }
    
    func registerLocalDatabase() {
        self.syncObjects.forEach { object in
            DispatchQueue.main.async {
                object.registerLocalDatabase()
            }
        }
    }
    
    private func fetchChangesInZones(_ callback: ((Error?) -> Void)? = nil) {
        let changesOp = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIds, optionsByRecordZoneID: zoneIdOptions)
        changesOp.fetchAllChanges = true
        
        changesOp.recordZoneChangeTokensUpdatedBlock = { [weak self] zoneId, token, _ in
            guard let self = self else { return }
            self.zoneChangesToken = token
        }
        
        changesOp.recordChangedBlock = { [weak self] record in
            /// The Cloud will return the modified record since the last zoneChangesToken, we need to do local cache here.
            /// Handle the record:
            guard let self = self else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.recordType == record.recordType }) else { return }
            syncObject.add(record: record)
        }
        
        changesOp.recordWithIDWasDeletedBlock = { [weak self] recordId, _ in
            guard let self = self else { return }
            self.syncObjects.forEach { $0.delete(recordID: recordId) } // TODO: Probably a more efficient way than this
        }
        
        changesOp.recordZoneFetchCompletionBlock = { [weak self](zoneId, token, _, _, error) in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.zoneChangesToken = token
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    self.fetchChangesInZones(callback)
                })
            case .recoverableError(let reason, _):
                switch reason {
                case .changeTokenExpired:
                    /// The previousServerChangeToken value is too old and the client must re-sync from scratch
                    self.zoneChangesToken = nil
                    self.fetchChangesInZones(callback)
                default:
                    return
                }
            default:
                return
            }
        }
        
        changesOp.fetchRecordZoneChangesCompletionBlock = { error in
            callback?(error)
        }
        
        database.add(changesOp)
    }
}

extension PrivateDatabaseManager {
    /// The changes token, for more please reference to https://developer.apple.com/videos/play/wwdc2016/231/
    var databaseChangeToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: IceCreamKey.databaseChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: IceCreamKey.databaseChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: IceCreamKey.databaseChangesTokenKey.value)
        }
    }
    
    var subscriptionIsLocallyCached: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: IceCreamKey.subscriptionIsLocallyCachedKey.value) as? Bool  else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: IceCreamKey.subscriptionIsLocallyCachedKey.value)
        }
    }
    
    private var zoneIds: [CKRecordZone.ID] {
        return syncObjects.map { $0.zoneID } // TODO: It's all the same zoneID, so maybe just the first or a value somewhere else...
    }

    private var zoneIdOptions: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] {
        return syncObjects.reduce([CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions]()) { (dict, syncObject) -> [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] in
            var dict = dict
            let zoneChangesOptions = CKFetchRecordZoneChangesOperation.ZoneOptions()
            zoneChangesOptions.previousServerChangeToken = self.zoneChangesToken
            dict[syncObject.zoneID] = zoneChangesOptions
            return dict
        }
    }
    
    @objc func cleanUp() {
        for syncObject in syncObjects {
            syncObject.cleanUp()
        }
    }
}
