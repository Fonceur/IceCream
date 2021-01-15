//
//  SyncEngine.swift
//  IceCream
//
//  Created by 蔡越 on 08/11/2017.
//

import CloudKit

/// SyncEngine talks to CloudKit directly.
/// Logically,
/// 1. it takes care of the operations of **CKDatabase**
/// 2. it handles all of the CloudKit config stuffs, such as subscriptions
/// 3. it hands over CKRecordZone stuffs to SyncObject so that it can have an effect on local Realm Database

public final class SyncEngine {
    
    private let databaseManager: DatabaseManager
    
    public convenience init(objects: [Syncable], databaseScope: CKDatabase.Scope = .private, container: CKContainer = .default(), completionHandler: ((Error?) -> Void)? = nil) {
        switch databaseScope {
        case .private:
            let privateDatabaseManager = PrivateDatabaseManager(objects: objects, container: container)
            self.init(databaseManager: privateDatabaseManager, completionHandler: completionHandler)
        case .public:
            let publicDatabaseManager = PublicDatabaseManager(objects: objects, container: container)
            self.init(databaseManager: publicDatabaseManager, completionHandler: completionHandler)
        default:
            fatalError("Not supported yet")
        }
    }
    
    private init(databaseManager: DatabaseManager, completionHandler: ((Error?) -> Void)?) {
        self.databaseManager = databaseManager
        setup(completionHandler: completionHandler)
    }
    
    private func setup(completionHandler: ((Error?) -> Void)?) {
        databaseManager.prepare()
        databaseManager.container.accountStatus { [weak self] (status, error) in
            guard let self = self else {
                completionHandler?(error)
                return
            }
            
            switch status {
            case .available:
                self.databaseManager.registerLocalDatabase()
                self.databaseManager.createCustomZonesIfAllowed()
                self.databaseManager.fetchChangesInDatabase(completionHandler)
                self.databaseManager.resumeLongLivedOperationIfPossible()
                self.databaseManager.startObservingRemoteChanges()
                self.databaseManager.startObservingTermination()
                self.databaseManager.createDatabaseSubscriptionIfHaveNot()
            case .noAccount, .restricted:
                guard self.databaseManager is PublicDatabaseManager else {
                    completionHandler?(error)
                    break
                }
                self.databaseManager.fetchChangesInDatabase(completionHandler)
                self.databaseManager.resumeLongLivedOperationIfPossible()
                self.databaseManager.startObservingRemoteChanges()
                self.databaseManager.startObservingTermination()
                self.databaseManager.createDatabaseSubscriptionIfHaveNot()
            case .couldNotDetermine:
                completionHandler?(error)
                break
            @unknown default:
                completionHandler?(error)
                break
            }
        }
    }
}

// MARK: Public Method
extension SyncEngine {
    
    /// Fetch data on the CloudKit and merge with local
    ///
    /// - Parameter completionHandler: Supported in the `privateCloudDatabase` when the fetch data process completes, completionHandler will be called. The error will be returned when anything wrong happens. Otherwise the error will be `nil`.
    public func pull(completionHandler: ((Error?) -> Void)? = nil) {
        databaseManager.fetchChangesInDatabase(completionHandler)
    }
    
    /// Push all existing local data to CloudKit
    /// You should NOT to call this method too frequently
    public func pushAll() {
        databaseManager.syncObjects.forEach { $0.pushLocalObjectsToCloudKit() }
    }
}

public enum Notifications: String, NotificationName {
    case cloudKitDataDidChangeRemotely
}

public enum IceCreamKey: String {
    /// Tokens
    case databaseChangesTokenKey
    case zoneChangesTokenKey
    case zonePublicChangesTokenKey
    
    /// Flags
    case subscriptionIsLocallyCachedKey
    case hasCustomZoneCreatedKey
    case hasCustomPublicZoneCreatedKey

    var value: String {
        return "icecream.keys." + rawValue
    }
}

/// Dangerous part:
/// In most cases, you should not change the string value cause it is related to user settings.
/// e.g.: the cloudKitSubscriptionID, if you don't want to use "private_changes" and use another string. You should remove the old subsription first.
/// Or your user will not save the same subscription again. So you got trouble.
/// The right way is remove old subscription first and then save new subscription.
public enum IceCreamSubscription: String, CaseIterable {
    case cloudKitPrivateDatabaseSubscriptionID = "private_changes"
    case cloudKitPublicDatabaseSubscriptionID = "cloudKitPublicDatabaseSubcriptionID"
    
    var id: String {
        return rawValue
    }
    
    public static var allIDs: [String] {
        return IceCreamSubscription.allCases.map { $0.rawValue }
    }
}
