import Foundation

private enum MetadataPrefix: Int8 {
    case ChatListInitialized = 0
    case PeerHistoryInitialized = 1
    case PeerNextMessageIdByNamespace = 2
    case NextStableMessageId = 3
    case ChatListTotalUnreadState = 4
    case NextPeerOperationLogIndex = 5
    case ChatListGroupInitialized = 6
    case GroupFeedIndexInitialized = 7
}

public struct ChatListTotalUnreadCounters: PostboxCoding, Equatable {
    public var messageCount: Int32
    
    public init(messageCount: Int32) {
        self.messageCount = messageCount
    }
    
    public init(decoder: PostboxDecoder) {
        self.messageCount = decoder.decodeInt32ForKey("m", orElse: 0)
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.messageCount, forKey: "m")
    }
    
    public static func ==(lhs: ChatListTotalUnreadCounters, rhs: ChatListTotalUnreadCounters) -> Bool {
        if lhs.messageCount != rhs.messageCount {
            return false
        }
        return true
    }
}

public struct ChatListTotalUnreadState: PostboxCoding, Equatable {
    public var absoluteCounters: ChatListTotalUnreadCounters
    public var filteredCounters: ChatListTotalUnreadCounters
    
    public init(absoluteCounters: ChatListTotalUnreadCounters, filteredCounters: ChatListTotalUnreadCounters) {
        self.absoluteCounters = absoluteCounters
        self.filteredCounters = filteredCounters
    }
    
    public init(decoder: PostboxDecoder) {
        self.absoluteCounters = decoder.decodeObjectForKey("a", decoder: { ChatListTotalUnreadCounters(decoder: $0) }) as! ChatListTotalUnreadCounters
        self.filteredCounters = decoder.decodeObjectForKey("f", decoder: { ChatListTotalUnreadCounters(decoder: $0) }) as! ChatListTotalUnreadCounters
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeObject(self.absoluteCounters, forKey: "a")
        encoder.encodeObject(self.filteredCounters, forKey: "f")
    }
    
    public static func ==(lhs: ChatListTotalUnreadState, rhs: ChatListTotalUnreadState) -> Bool {
        if lhs.absoluteCounters != rhs.absoluteCounters {
            return false
        }
        if lhs.filteredCounters != rhs.filteredCounters {
            return false
        }
        return true
    }
}

private enum InitializedChatListKey: Hashable {
    case global
    case group(PeerGroupId)
    
    init(_ groupId: PeerGroupId?) {
        if let groupId = groupId {
            self = .group(groupId)
        } else {
            self = .global
        }
    }
    
    var rawValue: Int32 {
        switch self {
            case .global:
                return 0
            case let .group(groupId):
                return groupId.rawValue
        }
    }
    
    var hashValue: Int {
        switch self {
            case .global:
                return 0
            case let .group(groupId):
                return groupId.hashValue
        }
    }
    
    static func ==(lhs: InitializedChatListKey, rhs: InitializedChatListKey) -> Bool {
        switch lhs {
            case .global:
                if case .global = rhs {
                    return true
                } else {
                    return false
                }
            case let .group(groupId):
                if case .group(groupId) = rhs {
                    return true
                } else {
                    return false
                }
        }
    }
}

final class MessageHistoryMetadataTable: Table {
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .binary)
    }
    
    let sharedPeerHistoryInitializedKey = ValueBoxKey(length: 8 + 1)
    let sharedGroupFeedIndexInitializedKey = ValueBoxKey(length: 4 + 1)
    let sharedChatListGroupHistoryInitializedKey = ValueBoxKey(length: 4 + 1)
    let sharedPeerNextMessageIdByNamespaceKey = ValueBoxKey(length: 8 + 1 + 4)
    let sharedBuffer = WriteBuffer()
    
    private var initializedChatList = Set<InitializedChatListKey>()
    private var initializedHistoryPeerIds = Set<PeerId>()
    private var initializedGroupFeedIndexIds = Set<PeerGroupId>()
    
    private var peerNextMessageIdByNamespace: [PeerId: [MessageId.Namespace: MessageId.Id]] = [:]
    private var updatedPeerNextMessageIdByNamespace: [PeerId: Set<MessageId.Namespace>] = [:]
    
    private var nextMessageStableId: UInt32?
    private var nextMessageStableIdUpdated = false
    
    private var chatListTotalUnreadState: ChatListTotalUnreadState?
    private var chatListTotalUnreadStateUpdated = false
    
    private var nextPeerOperationLogIndex: UInt32?
    private var nextPeerOperationLogIndexUpdated = false
    
    private var currentPinnedChatPeerIds: Set<PeerId>?
    private var currentPinnedChatPeerIdsUpdated = false
    
    private func peerHistoryInitializedKey(_ id: PeerId) -> ValueBoxKey {
        self.sharedPeerHistoryInitializedKey.setInt64(0, value: id.toInt64())
        self.sharedPeerHistoryInitializedKey.setInt8(8, value: MetadataPrefix.PeerHistoryInitialized.rawValue)
        return self.sharedPeerHistoryInitializedKey
    }
    
    private func groupFeedIndexInitializedKey(_ id: PeerGroupId) -> ValueBoxKey {
        self.sharedGroupFeedIndexInitializedKey.setInt32(0, value: id.rawValue)
        self.sharedGroupFeedIndexInitializedKey.setInt8(4, value: MetadataPrefix.GroupFeedIndexInitialized.rawValue)
        return self.sharedGroupFeedIndexInitializedKey
    }
    
    private func chatListGroupInitializedKey(_ key: InitializedChatListKey) -> ValueBoxKey {
        self.sharedChatListGroupHistoryInitializedKey.setInt32(0, value: key.rawValue)
        self.sharedChatListGroupHistoryInitializedKey.setInt8(8, value: MetadataPrefix.ChatListGroupInitialized.rawValue)
        return self.sharedChatListGroupHistoryInitializedKey
    }
    
    private func peerNextMessageIdByNamespaceKey(_ id: PeerId, namespace: MessageId.Namespace) -> ValueBoxKey {
        self.sharedPeerNextMessageIdByNamespaceKey.setInt64(0, value: id.toInt64())
        self.sharedPeerNextMessageIdByNamespaceKey.setInt8(8, value: MetadataPrefix.PeerNextMessageIdByNamespace.rawValue)
        self.sharedPeerNextMessageIdByNamespaceKey.setInt32(8 + 1, value: namespace)
        
        return self.sharedPeerNextMessageIdByNamespaceKey
    }
    
    private func key(_ prefix: MetadataPrefix) -> ValueBoxKey {
        let key = ValueBoxKey(length: 1)
        key.setInt8(0, value: prefix.rawValue)
        return key
    }
    
    func setInitializedChatList(groupId: PeerGroupId?) {
        if groupId == nil {
            self.valueBox.set(self.table, key: self.key(MetadataPrefix.ChatListInitialized), value: MemoryBuffer())
        } else {
            self.valueBox.set(self.table, key: self.chatListGroupInitializedKey(InitializedChatListKey(groupId)), value: MemoryBuffer())
        }
        self.initializedChatList.insert(InitializedChatListKey(groupId))
    }
    
    func isInitializedChatList(groupId: PeerGroupId?) -> Bool {
        let key = InitializedChatListKey(groupId)
        if self.initializedChatList.contains(key) {
            return true
        } else {
            if groupId == nil {
                if self.valueBox.exists(self.table, key: self.key(MetadataPrefix.ChatListInitialized)) {
                    self.initializedChatList.insert(key)
                    return true
                } else {
                    return false
                }
            } else {
                if self.valueBox.exists(self.table, key: self.chatListGroupInitializedKey(key)) {
                    self.initializedChatList.insert(key)
                    return true
                } else {
                    return false
                }
            }
        }
    }
    
    func setInitialized(_ peerId: PeerId) {
        self.initializedHistoryPeerIds.insert(peerId)
        self.sharedBuffer.reset()
        self.valueBox.set(self.table, key: self.peerHistoryInitializedKey(peerId), value: self.sharedBuffer)
    }
    
    func isInitialized(_ peerId: PeerId) -> Bool {
        if self.initializedHistoryPeerIds.contains(peerId) {
            return true
        } else {
            if self.valueBox.exists(self.table, key: self.peerHistoryInitializedKey(peerId)) {
                self.initializedHistoryPeerIds.insert(peerId)
                return true
            } else {
                return false
            }
        }
    }
    
    func setGroupFeedIndexInitialized(_ groupId: PeerGroupId) {
        self.initializedGroupFeedIndexIds.insert(groupId)
        self.sharedBuffer.reset()
        self.valueBox.set(self.table, key: self.groupFeedIndexInitializedKey(groupId), value: self.sharedBuffer)
    }
    
    func isGroupFeedIndexInitialized(_ groupId: PeerGroupId) -> Bool {
        if self.initializedGroupFeedIndexIds.contains(groupId) {
            return true
        } else {
            if self.valueBox.exists(self.table, key: self.groupFeedIndexInitializedKey(groupId)) {
                self.initializedGroupFeedIndexIds.insert(groupId)
                return true
            } else {
                return false
            }
        }
    }
    
    func getNextMessageIdAndIncrement(_ peerId: PeerId, namespace: MessageId.Namespace) -> MessageId {
        if let messageIdByNamespace = self.peerNextMessageIdByNamespace[peerId] {
            if let nextId = messageIdByNamespace[namespace] {
                self.peerNextMessageIdByNamespace[peerId]![namespace] = nextId + 1
                if updatedPeerNextMessageIdByNamespace[peerId] != nil {
                    updatedPeerNextMessageIdByNamespace[peerId]!.insert(namespace)
                } else {
                    updatedPeerNextMessageIdByNamespace[peerId] = Set<MessageId.Namespace>([namespace])
                }
                return MessageId(peerId: peerId, namespace: namespace, id: nextId)
            } else {
                var nextId: Int32 = 1
                if let value = self.valueBox.get(self.table, key: self.peerNextMessageIdByNamespaceKey(peerId, namespace: namespace)) {
                    value.read(&nextId, offset: 0, length: 4)
                }
                self.peerNextMessageIdByNamespace[peerId]![namespace] = nextId + 1
                if updatedPeerNextMessageIdByNamespace[peerId] != nil {
                    updatedPeerNextMessageIdByNamespace[peerId]!.insert(namespace)
                } else {
                    updatedPeerNextMessageIdByNamespace[peerId] = Set<MessageId.Namespace>([namespace])
                }
                return MessageId(peerId: peerId, namespace: namespace, id: nextId)
            }
        } else {
            var nextId: Int32 = 1
            if let value = self.valueBox.get(self.table, key: self.peerNextMessageIdByNamespaceKey(peerId, namespace: namespace)) {
                value.read(&nextId, offset: 0, length: 4)
            }
            
            self.peerNextMessageIdByNamespace[peerId] = [namespace: nextId + 1]
            if updatedPeerNextMessageIdByNamespace[peerId] != nil {
                updatedPeerNextMessageIdByNamespace[peerId]!.insert(namespace)
            } else {
                updatedPeerNextMessageIdByNamespace[peerId] = Set<MessageId.Namespace>([namespace])
            }
            return MessageId(peerId: peerId, namespace: namespace, id: nextId)
        }
    }
    
    func getNextStableMessageIndexId() -> UInt32 {
        if let nextId = self.nextMessageStableId {
            self.nextMessageStableId = nextId + 1
            self.nextMessageStableIdUpdated = true
            return nextId
        } else {
            if let value = self.valueBox.get(self.table, key: self.key(.NextStableMessageId)) {
                var nextId: UInt32 = 0
                value.read(&nextId, offset: 0, length: 4)
                self.nextMessageStableId = nextId + 1
                self.nextMessageStableIdUpdated = true
                return nextId
            } else {
                let nextId: UInt32 = 1
                self.nextMessageStableId = nextId + 1
                self.nextMessageStableIdUpdated = true
                return nextId
            }
        }
    }
    
    func getNextPeerOperationLogIndex() -> UInt32 {
        if let nextId = self.nextPeerOperationLogIndex {
            self.nextPeerOperationLogIndex = nextId + 1
            self.nextPeerOperationLogIndexUpdated = true
            return nextId
        } else {
            if let value = self.valueBox.get(self.table, key: self.key(.NextPeerOperationLogIndex)) {
                var nextId: UInt32 = 0
                value.read(&nextId, offset: 0, length: 4)
                self.nextPeerOperationLogIndex = nextId + 1
                self.nextPeerOperationLogIndexUpdated = true
                return nextId
            } else {
                let nextId: UInt32 = 1
                self.nextPeerOperationLogIndex = nextId + 1
                self.nextPeerOperationLogIndexUpdated = true
                return nextId
            }
        }
    }
    
    func getChatListTotalUnreadState() -> ChatListTotalUnreadState {
        if let cached = self.chatListTotalUnreadState {
            return cached
        } else {
            if let value = self.valueBox.get(self.table, key: self.key(.ChatListTotalUnreadState)), let state = PostboxDecoder(buffer: value).decodeObjectForKey("_", decoder: {
                ChatListTotalUnreadState(decoder: $0)
            }) as? ChatListTotalUnreadState {
                self.chatListTotalUnreadState = state
                return state
            } else {
                let state = ChatListTotalUnreadState(absoluteCounters: ChatListTotalUnreadCounters(messageCount: 0), filteredCounters: ChatListTotalUnreadCounters(messageCount: 0))
                self.chatListTotalUnreadState = state
                return state
            }
        }
    }
    
    func setChatListTotalUnreadState(_ state: ChatListTotalUnreadState) {
        let current = self.getChatListTotalUnreadState()
        if current != state {
            self.chatListTotalUnreadState = state
            self.chatListTotalUnreadStateUpdated = true
        }
    }
    
    override func clearMemoryCache() {
        self.initializedChatList.removeAll()
        self.initializedHistoryPeerIds.removeAll()
        self.peerNextMessageIdByNamespace.removeAll()
        self.updatedPeerNextMessageIdByNamespace.removeAll()
        self.nextMessageStableId = nil
        self.nextMessageStableIdUpdated = false
        self.chatListTotalUnreadState = nil
        self.chatListTotalUnreadStateUpdated = false
    }
    
    override func beforeCommit() {
        let sharedBuffer = WriteBuffer()
        for (peerId, namespaces) in self.updatedPeerNextMessageIdByNamespace {
            for namespace in namespaces {
                if let messageIdByNamespace = self.peerNextMessageIdByNamespace[peerId], let maxId = messageIdByNamespace[namespace] {
                    sharedBuffer.reset()
                    var mutableMaxId = maxId
                    sharedBuffer.write(&mutableMaxId, offset: 0, length: 4)
                    self.valueBox.set(self.table, key: self.peerNextMessageIdByNamespaceKey(peerId, namespace: namespace), value: sharedBuffer)
                } else {
                    self.valueBox.remove(self.table, key: self.peerNextMessageIdByNamespaceKey(peerId, namespace: namespace))
                }
            }
        }
        self.updatedPeerNextMessageIdByNamespace.removeAll()
        
        if self.nextMessageStableIdUpdated {
            if let nextMessageStableId = self.nextMessageStableId {
                var nextId: UInt32 = nextMessageStableId
                self.valueBox.set(self.table, key: self.key(.NextStableMessageId), value: MemoryBuffer(memory: &nextId, capacity: 4, length: 4, freeWhenDone: false))
                self.nextMessageStableIdUpdated = false
            }
        }
        
        if self.nextPeerOperationLogIndexUpdated {
            if let nextPeerOperationLogIndex = self.nextPeerOperationLogIndex {
                var nextId: UInt32 = nextPeerOperationLogIndex
                self.valueBox.set(self.table, key: self.key(.NextPeerOperationLogIndex), value: MemoryBuffer(memory: &nextId, capacity: 4, length: 4, freeWhenDone: false))
                self.nextPeerOperationLogIndexUpdated = false
            }
        }
        
        if self.chatListTotalUnreadStateUpdated {
            if let state = self.chatListTotalUnreadState {
                let buffer = PostboxEncoder()
                buffer.encodeObject(state, forKey: "_")
                self.valueBox.set(self.table, key: self.key(.ChatListTotalUnreadState), value: buffer.readBufferNoCopy())
            }
            self.chatListTotalUnreadStateUpdated = false
        }
    }
}
