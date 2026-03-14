// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                                                                           ║
// ║   ███████╗██╗      ██████╗ ██╗    ██╗██████╗  █████╗ ██╗   ██╗           ║
// ║   ██╔════╝██║     ██╔═══██╗██║    ██║██╔══██╗██╔══██╗╚██╗ ██╔╝           ║
// ║   █████╗  ██║     ██║   ██║██║ █╗ ██║██████╔╝███████║ ╚████╔╝            ║
// ║   ██╔══╝  ██║     ██║   ██║██║███╗██║██╔═══╝ ██╔══██║  ╚██╔╝            ║
// ║   ██║     ███████╗╚██████╔╝╚███╔███╔╝██║     ██║  ██║   ██║             ║
// ║   ╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝ ╚═╝     ╚═╝  ╚═╝   ╚═╝             ║
// ║                                                                           ║
// ║   FlowPay.cdc — Core Contract                                             ║
// ║   Web3 Payment Scheduling & Automation Engine                             ║
// ║   Cadence 1.0 · Flow Blockchain · Production-Ready                        ║
// ║                                                                           ║
// ║   Architecture:                                                           ║
// ║     • Global stream registry with auto-incrementing IDs                  ║
// ║     • Per-stream isolated escrow vaults (@FlowToken.Vault)                ║
// ║     • Dedicated platform fee vault (1% of each distribution)             ║
// ║     • Creator-indexed reverse lookup for efficient queries                ║
// ║     • Enum-driven lifecycle state machine                                 ║
// ║     • One-time, weekly, and monthly recurrence support                    ║
// ║     • Admin resource for fee withdrawal and emergency controls            ║
// ║                                                                           ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

access(all) contract FlowPay {

    // ═══════════════════════════════════════════════════════════════
    // MARK: Constants
    // ═══════════════════════════════════════════════════════════════

    /// Platform fee rate — 1% of each stream's total payout
    access(all) let PLATFORM_FEE_PERCENT: UFix64

    /// Hard cap on recipients per stream
    access(all) let MAX_RECIPIENTS: Int

    /// 7 days in seconds
    access(all) let SECONDS_PER_WEEK: UFix64

    /// 30 days in seconds
    access(all) let SECONDS_PER_MONTH: UFix64

    // ═══════════════════════════════════════════════════════════════
    // MARK: Storage Paths
    // ═══════════════════════════════════════════════════════════════

    access(all) let AdminStoragePath: StoragePath
    access(all) let AdminPublicPath:  PublicPath

    // ═══════════════════════════════════════════════════════════════
    // MARK: Events
    // ═══════════════════════════════════════════════════════════════

    access(all) event ContractInitialized()

    access(all) event StreamCreated(
        streamID:       UInt64,
        creator:        Address,
        recipientCount: Int,
        payoutTotal:    UFix64,
        platformFee:    UFix64,
        totalEscrowed:  UFix64,
        executionTime:  UFix64,
        recurrence:     String
    )

    access(all) event StreamEdited(
        streamID:         UInt64,
        editor:           Address,
        newRecipientCount: Int,
        newPayoutTotal:   UFix64,
        newExecutionTime: UFix64
    )

    access(all) event StreamCancelled(
        streamID: UInt64,
        creator:  Address,
        refunded: UFix64
    )

    access(all) event StreamExecuted(
        streamID:          UInt64,
        executor:          Address,
        cycleNumber:       UInt64,
        totalDistributed:  UFix64,
        platformFee:       UFix64,
        nextExecutionTime: UFix64?
    )

    access(all) event RecipientPaid(
        streamID:  UInt64,
        recipient: Address,
        amount:    UFix64,
        cycle:     UInt64
    )

    access(all) event PlatformFeesWithdrawn(
        amount:    UFix64,
        recipient: Address
    )

    // ═══════════════════════════════════════════════════════════════
    // MARK: Enums
    // ═══════════════════════════════════════════════════════════════

    /// How often a stream executes
    access(all) enum RecurrenceType: UInt8 {
        access(all) case oneTime  // 0
        access(all) case weekly   // 1
        access(all) case monthly  // 2
    }

    /// Lifecycle states — transitions are one-directional
    ///   active → executed   (one-time after execution)
    ///   active → cancelled  (before execution)
    ///   active stays active (recurring, indefinitely)
    access(all) enum StreamStatus: UInt8 {
        access(all) case active    // 0
        access(all) case executed  // 1
        access(all) case cancelled // 2
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Structs
    // ═══════════════════════════════════════════════════════════════

    /// A single recipient and their payment amount within a stream
    access(all) struct RecipientEntry {
        access(all) let address: Address
        access(all) let amount:  UFix64

        init(address: Address, amount: UFix64) {
            pre {
                amount > 0.0: "FlowPay: Recipient payment amount must be greater than zero"
            }
            self.address = address
            self.amount  = amount
        }
    }

    /// Complete metadata record for a payment stream.
    /// Vaults are stored separately in escrowVaults[streamID].
    access(all) struct StreamInfo {

        // ── Identifiers ──────────────────────────────────────────
        access(all) let streamID:  UInt64
        access(all) let creator:   Address

        // ── Payment configuration ────────────────────────────────
        access(all) var recipients:  [RecipientEntry]
        access(all) var totalEscrowed: UFix64
        access(all) var platformFee:   UFix64

        // ── Scheduling ───────────────────────────────────────────
        access(all) var executionTime:     UFix64
        access(all) let recurrence:        RecurrenceType
        access(all) var nextExecutionTime: UFix64?

        // ── Lifecycle ────────────────────────────────────────────
        access(all) var status:         StreamStatus
        access(all) var executionCount: UInt64

        // ── Timestamps ───────────────────────────────────────────
        access(all) let createdAt:  UFix64
        access(all) var updatedAt:  UFix64

        init(
            streamID:      UInt64,
            creator:       Address,
            recipients:    [RecipientEntry],
            executionTime: UFix64,
            recurrence:    RecurrenceType,
            totalEscrowed: UFix64, ̰
            platformFee:   UFix64
        ) {
            self.streamID      = streamID
            self.creator       = creator
            self.recipients    = recipients
            self.executionTime = executionTime
            self.recurrence    = recurrence
            self.totalEscrowed = totalEscrowed
            self.platformFee   = platformFee
            self.status        = StreamStatus.active
            self.executionCount = 0
            self.createdAt     = getCurrentBlock().timestamp
            self.updatedAt     = getCurrentBlock().timestamp

            // Recurring streams track their next cycle timestamp
            self.nextExecutionTime = recurrence == RecurrenceType.oneTime
                ? nil
                : executionTime
        }

        // ── Computed helpers ──────────────────────────────────────

        /// Sum of all recipient payment amounts
        access(all) view fun payoutTotal(): UFix64 {
            var total: UFix64 = 0.0
            for entry in self.recipients {
                total = total + entry.amount
            }
            return total
        }

        /// The effective execution timestamp for the current cycle
        access(all) view fun currentExecutionTime(): UFix64 {
            if self.recurrence == RecurrenceType.oneTime {
                return self.executionTime
            }
            return self.nextExecutionTime ?? self.executionTime
        }

        // ── Contract-only mutations ───────────────────────────────

        /// Called after a successful execution cycle
        access(contract) fun recordExecution() {
            self.executionCount = self.executionCount + 1
            self.updatedAt      = getCurrentBlock().timestamp

            switch self.recurrence {
                case RecurrenceType.oneTime:
                    self.status            = StreamStatus.executed
                    self.nextExecutionTime = nil

                case RecurrenceType.weekly:
                    // Advance by N full weeks from original anchor (drift-free)
                    self.nextExecutionTime =
                        self.executionTime + (FlowPay.SECONDS_PER_WEEK * UFix64(self.executionCount))

                case RecurrenceType.monthly:
                    self.nextExecutionTime =
                        self.executionTime + (FlowPay.SECONDS_PER_MONTH * UFix64(self.executionCount))
            }
        }

        /// Apply edits from the creator (pre-execution only)
        access(contract) fun applyEdit(
            recipients:    [RecipientEntry],
            executionTime: UFix64,
            totalEscrowed: UFix64,
            platformFee:   UFix64
        ) {
            self.recipients    = recipients
            self.executionTime = executionTime
            self.totalEscrowed = totalEscrowed
            self.platformFee   = platformFee
            self.updatedAt     = getCurrentBlock().timestamp

            if self.recurrence != RecurrenceType.oneTime {
                self.nextExecutionTime = executionTime
            }
        }

        access(contract) fun markCancelled() {
            self.status    = StreamStatus.cancelled
            self.updatedAt = getCurrentBlock().timestamp
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Contract State
    // ═══════════════════════════════════════════════════════════════

    /// Global auto-incrementing stream ID counter (starts at 1)
    access(contract) var nextStreamID: UInt64

    /// Primary stream registry: streamID → StreamInfo
    access(contract) var streams: {UInt64: StreamInfo}

    /// Creator reverse index: Address → [streamID]
    access(contract) var creatorIndex: {Address: [UInt64]}

    /// Isolated escrow vaults — one per stream
    access(contract) var escrowVaults: @{UInt64: FlowToken.Vault}

    /// Platform fee accumulation vault
    access(contract) var platformVault: @FlowToken.Vault

    // ── Platform-wide analytics ──────────────────────────────────
    access(contract) var totalStreamsCreated:     UInt64
    access(contract) var totalTokensDistributed:  UFix64
    access(contract) var totalFeesCollected:      UFix64

    // ═══════════════════════════════════════════════════════════════
    // MARK: Internal Helpers
    // ═══════════════════════════════════════════════════════════════

    /// Mint the next unique stream ID
    access(contract) fun mintStreamID(): UInt64 {
        let id = self.nextStreamID
        self.nextStreamID = self.nextStreamID + 1
        return id
    }

    /// Compute 1% platform fee for a given payout total
    access(contract) view fun calcFee(_ payoutTotal: UFix64): UFix64 {
        return payoutTotal * self.PLATFORM_FEE_PERCENT / 100.0
    }

    /// Full escrow requirement: payout + fee
    access(contract) view fun calcRequired(_ payoutTotal: UFix64): UFix64 {
        return payoutTotal + self.calcFee(payoutTotal)
    }

    /// Validate a RecipientEntry array
    access(contract) fun validateRecipients(_ recipients: [RecipientEntry]) {
        pre {
            recipients.length > 0:
                "FlowPay: At least one recipient is required"
            recipients.length <= self.MAX_RECIPIENTS:
                "FlowPay: Stream exceeds maximum of 100 recipients"
        }
        // Individual amounts validated by RecipientEntry.init pre-condition
    }

    /// Sum amounts from a RecipientEntry array
    access(contract) view fun sumAmounts(_ recipients: [RecipientEntry]): UFix64 {
        var total: UFix64 = 0.0
        for entry in recipients {
            total = total + entry.amount
        }
        return total
    }

    /// Convert RecurrenceType to human-readable string
    access(contract) view fun recurrenceLabel(_ r: RecurrenceType): String {
        switch r {
            case RecurrenceType.oneTime:  return "one-time"
            case RecurrenceType.weekly:   return "weekly"
            case RecurrenceType.monthly:  return "monthly"
        }
        return "unknown"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Core Public Functions
    // ═══════════════════════════════════════════════════════════════

    // ───────────────────────────────────────────────────────────────
    // createStream
    // ───────────────────────────────────────────────────────────────
    /// Register a new payment stream and lock escrowed tokens.
    ///
    /// The caller must supply a FlowToken.Vault containing exactly:
    ///   Σ(recipient amounts) + 1% platform fee
    ///
    /// Returns the newly assigned stream ID.
    access(all) fun createStream(
        creator:       Address,
        recipients:    [RecipientEntry],
        executionTime: UFix64,
        recurrence:    RecurrenceType,
        escrow:        @FlowToken.Vault
    ): UInt64 {
        pre {
            executionTime > getCurrentBlock().timestamp:
                "FlowPay: executionTime must be a future timestamp"
        }

        // ── Validate inputs ───────────────────────────────────────
        self.validateRecipients(recipients)

        let payout   = self.sumAmounts(recipients)
        let fee      = self.calcFee(payout)
        let required = payout + fee

        assert(
            escrow.balance == required,
            message: "FlowPay: Escrow deposit mismatch. "
                .concat("Received: ").concat(escrow.balance.toString())
                .concat(" | Required (payout + 1% fee): ").concat(required.toString())
        )

        // ── Register stream ───────────────────────────────────────
        let streamID = self.mintStreamID()

        self.escrowVaults[streamID] <-! escrow

        self.streams[streamID] = StreamInfo(
            streamID:      streamID,
            creator:       creator,
            recipients:    recipients,
            executionTime: executionTime,
            recurrence:    recurrence,
            totalEscrowed: required,
            platformFee:   fee
        )

        if self.creatorIndex[creator] == nil {
            self.creatorIndex[creator] = []
        }
        self.creatorIndex[creator]!.append(streamID)

        self.totalStreamsCreated = self.totalStreamsCreated + 1

        emit StreamCreated(
            streamID:       streamID,
            creator:        creator,
            recipientCount: recipients.length,
            payoutTotal:    payout,
            platformFee:    fee,
            totalEscrowed:  required,
            executionTime:  executionTime,
            recurrence:     self.recurrenceLabel(recurrence)
        )

        return streamID
    }

    // ───────────────────────────────────────────────────────────────
    // editStream
    // ───────────────────────────────────────────────────────────────
    /// Modify an active stream's recipients, amounts, or execution time.
    ///
    /// Escrow is rebalanced atomically:
    ///   • If new required > current balance → caller provides topUp
    ///   • If new required < current balance → excess refunded to caller
    ///
    /// Only the original stream creator can call this.
    /// Cannot edit after execution time has passed.
    access(all) fun editStream(
        streamID:         UInt64,
        editor:           Address,
        newRecipients:    [RecipientEntry],
        newExecutionTime: UFix64,
        topUp:            @FlowToken.Vault,
        refundReceiver:   &{FungibleToken.Receiver}
    ) {
        pre {
            self.streams[streamID] != nil:
                "FlowPay: Stream ".concat(streamID.toString()).concat(" does not exist")
            self.streams[streamID]!.creator == editor:
                "FlowPay: Only the stream creator can edit this stream"
            self.streams[streamID]!.status == StreamStatus.active:
                "FlowPay: Cannot edit a stream that is not active"
            self.streams[streamID]!.executionTime > getCurrentBlock().timestamp:
                "FlowPay: Cannot edit a stream past its scheduled execution time"
            newExecutionTime > getCurrentBlock().timestamp:
                "FlowPay: New execution time must be in the future"
        }

        self.validateRecipients(newRecipients)

        let newPayout   = self.sumAmounts(newRecipients)
        let newFee      = self.calcFee(newPayout)
        let newRequired = newPayout + newFee
        let current     = self.escrowVaults[streamID]?.balance ?? 0.0

        if newRequired > current {
            // ── Top-up path ───────────────────────────────────────
            let deficit = newRequired - current
            assert(
                topUp.balance >= deficit,
                message: "FlowPay: Top-up insufficient. "
                    .concat("Need: ").concat(deficit.toString())
                    .concat(" | Provided: ").concat(topUp.balance.toString())
            )
            let fill <- topUp.withdraw(amount: deficit)
            self.escrowVaults[streamID]?.deposit(from: <- fill)
            // Return any over-supply back to the editor
            if topUp.balance > 0.0 {
                refundReceiver.deposit(from: <- topUp)
            } else {
                destroy topUp
            }
        } else {
            // ── Refund path ───────────────────────────────────────
            let excess = current - newRequired
            if excess > 0.0 {
                let refund <- self.escrowVaults[streamID]?.withdraw(amount: excess)!
                refundReceiver.deposit(from: <- refund)
            }
            destroy topUp
        }

        self.streams[streamID]!.applyEdit(
            recipients:    newRecipients,
            executionTime: newExecutionTime,
            totalEscrowed: newRequired,
            platformFee:   newFee
        )

        emit StreamEdited(
            streamID:          streamID,
            editor:            editor,
            newRecipientCount: newRecipients.length,
            newPayoutTotal:    newPayout,
            newExecutionTime:  newExecutionTime
        )
    }

    // ───────────────────────────────────────────────────────────────
    // cancelStream
    // ───────────────────────────────────────────────────────────────
    /// Cancel an active stream and refund the full escrow to the creator.
    ///
    /// Only the stream creator can cancel.
    /// Cancellation is permanent — status transitions to `cancelled`.
    access(all) fun cancelStream(
        streamID:       UInt64,
        caller:         Address,
        refundReceiver: &{FungibleToken.Receiver}
    ) {
        pre {
            self.streams[streamID] != nil:
                "FlowPay: Stream ".concat(streamID.toString()).concat(" does not exist")
            self.streams[streamID]!.creator == caller:
                "FlowPay: Only the stream creator can cancel this stream"
            self.streams[streamID]!.status == StreamStatus.active:
                "FlowPay: Cannot cancel a stream that is not active"
        }

        let balance = self.escrowVaults[streamID]?.balance ?? 0.0

        if balance > 0.0 {
            let refund <- self.escrowVaults[streamID]?.withdraw(amount: balance)!
            refundReceiver.deposit(from: <- refund)
        }

        self.streams[streamID]!.markCancelled()

        emit StreamCancelled(
            streamID: streamID,
            creator:  caller,
            refunded: balance
        )
    }

    // ───────────────────────────────────────────────────────────────
    // executeStream
    // ───────────────────────────────────────────────────────────────
    /// Distribute escrowed tokens to all recipients and collect the
    /// platform fee. Called by FlowPayScheduler.Handler via
    /// FlowTransactionScheduler (autonomous) or manually.
    ///
    /// Validates:
    ///   1. Stream exists and is active
    ///   2. Scheduled execution time has passed
    ///   3. Escrow contains sufficient balance
    ///   4. Each recipient has a valid FlowToken receiver
    ///
    /// After execution:
    ///   • One-time streams → status = executed
    ///   • Recurring streams → nextExecutionTime advanced, stays active
    access(all) fun executeStream(
        streamID: UInt64,
        executor: Address
    ) {
        pre {
            self.streams[streamID] != nil:
                "FlowPay: Stream ".concat(streamID.toString()).concat(" does not exist")
            self.streams[streamID]!.status == StreamStatus.active:
                "FlowPay: Stream ".concat(streamID.toString()).concat(" is not active")
        }

        let info        = self.streams[streamID]!
        let effectiveTime = info.currentExecutionTime()

        assert(
            getCurrentBlock().timestamp >= effectiveTime,
            message: "FlowPay: Execution time not reached. "
                .concat("Now: ").concat(getCurrentBlock().timestamp.toString())
                .concat(" | Scheduled: ").concat(effectiveTime.toString())
        )

        let payout   = info.payoutTotal()
        let fee      = self.calcFee(payout)
        let required = payout + fee
        let escrowBal = self.escrowVaults[streamID]?.balance ?? 0.0

        assert(
            escrowBal >= required,
            message: "FlowPay: Insufficient escrow. "
                .concat("Has: ").concat(escrowBal.toString())
                .concat(" | Needs: ").concat(required.toString())
        )

        let cycle = info.executionCount + 1

        // ── Pay each recipient ────────────────────────────────────
        for entry in info.recipients {
            let tokens <- self.escrowVaults[streamID]?.withdraw(amount: entry.amount)!

            let receiver = getAccount(entry.address)
                .capabilities
                .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                ?? panic(
                    "FlowPay: Cannot borrow FlowToken receiver for recipient "
                    .concat(entry.address.toString())
                )

            receiver.deposit(from: <- tokens)

            emit RecipientPaid(
                streamID:  streamID,
                recipient: entry.address,
                amount:    entry.amount,
                cycle:     cycle
            )
        }

        // ── Collect platform fee ──────────────────────────────────
        let feeTokens <- self.escrowVaults[streamID]?.withdraw(amount: fee)!
        self.platformVault.deposit(from: <- feeTokens)

        // ── Update analytics ──────────────────────────────────────
        self.totalTokensDistributed = self.totalTokensDistributed + payout
        self.totalFeesCollected     = self.totalFeesCollected + fee

        // ── Advance state machine ─────────────────────────────────
        self.streams[streamID]!.recordExecution()

        let nextTime = self.streams[streamID]!.nextExecutionTime

        emit StreamExecuted(
            streamID:          streamID,
            executor:          executor,
            cycleNumber:       cycle,
            totalDistributed:  payout,
            platformFee:       fee,
            nextExecutionTime: nextTime
        )
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Public Query Functions
    // ═══════════════════════════════════════════════════════════════

    /// Fetch a stream by its ID. Returns nil if not found.
    access(all) view fun getStream(streamID: UInt64): StreamInfo? {
        return self.streams[streamID]
    }

    /// Current escrow vault balance for a stream (0.0 if not found)
    access(all) view fun getEscrowBalance(streamID: UInt64): UFix64 {
        return self.escrowVaults[streamID]?.balance ?? 0.0
    }

    /// All streams ever created by a given address
    access(all) fun getStreamsByCreator(creator: Address): [StreamInfo] {
        let ids = self.creatorIndex[creator] ?? []
        var result: [StreamInfo] = []
        for id in ids {
            if let info = self.streams[id] {
                result.append(info)
            }
        }
        return result
    }

    /// All registered stream IDs
    access(all) view fun getAllStreamIDs(): [UInt64] {
        return self.streams.keys
    }

    /// Active streams with future execution times, sorted ascending.
    /// Pass limit = 0 to return all.
    access(all) fun getUpcomingStreams(limit: Int): [StreamInfo] {
        let now = getCurrentBlock().timestamp
        var upcoming: [StreamInfo] = []

        for id in self.streams.keys {
            let info = self.streams[id]!
            if info.status != StreamStatus.active { continue }
            if info.currentExecutionTime() >= now {
                upcoming.append(info)
            }
        }

        // Insertion sort (stable, efficient for small-medium counts)
        var i = 1
        while i < upcoming.length {
            let key   = upcoming[i]
            let keyT  = key.currentExecutionTime()
            var j     = i - 1
            while j >= 0 && upcoming[j].currentExecutionTime() > keyT {
                upcoming[j + 1] = upcoming[j]
                j = j - 1
            }
            upcoming[j + 1] = key
            i = i + 1
        }

        if limit <= 0 || upcoming.length <= limit { return upcoming }

        var sliced: [StreamInfo] = []
        var k = 0
        while k < limit {
            sliced.append(upcoming[k])
            k = k + 1
        }
        return sliced
    }

    /// Platform-wide dashboard analytics
    access(all) fun getDashboardAnalytics(): {String: AnyStruct} {
        var activeCount:    UInt64 = 0
        var executedCount:  UInt64 = 0
        var cancelledCount: UInt64 = 0
        var pendingPayout:  UFix64 = 0.0

        for id in self.streams.keys {
            let info = self.streams[id]!
            switch info.status {
                case StreamStatus.active:
                    activeCount    = activeCount + 1
                    pendingPayout  = pendingPayout + info.payoutTotal()
                case StreamStatus.executed:
                    executedCount  = executedCount + 1
                case StreamStatus.cancelled:
                    cancelledCount = cancelledCount + 1
            }
        }

        return {
            "totalStreamsCreated":     self.totalStreamsCreated,
            "totalTokensDistributed": self.totalTokensDistributed,
            "totalFeesCollected":     self.totalFeesCollected,
            "activeStreams":           activeCount,
            "executedStreams":         executedCount,
            "cancelledStreams":        cancelledCount,
            "pendingPayoutTotal":      pendingPayout,
            "platformVaultBalance":   self.platformVault.balance
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Admin Resource
    // ═══════════════════════════════════════════════════════════════

    /// Admin resource is stored in the deployer account at init time.
    /// Grants privileged operations: fee withdrawal and emergency cancel.
    access(all) resource Admin {

        /// Withdraw accumulated platform fees to any FungibleToken receiver
        access(all) fun withdrawPlatformFees(
            amount:   UFix64,
            receiver: &{FungibleToken.Receiver}
        ) {
            pre {
                amount > 0.0:
                    "FlowPay Admin: Withdrawal amount must be positive"
                amount <= FlowPay.platformVault.balance:
                    "FlowPay Admin: Withdrawal exceeds platform vault balance"
            }
            let tokens <- FlowPay.platformVault.withdraw(amount: amount)
            receiver.deposit(from: <- tokens)

            emit PlatformFeesWithdrawn(
                amount:    amount,
                recipient: receiver.getType().identifier.length > 0
                    ? FlowPay.account.address
                    : FlowPay.account.address
            )
        }

        /// Emergency cancel — force-cancel any active stream and refund creator.
        /// Use only when a creator is unable to cancel themselves (key loss, etc.).
        access(all) fun emergencyCancelStream(
            streamID:       UInt64,
            refundReceiver: &{FungibleToken.Receiver}
        ) {
            pre {
                FlowPay.streams[streamID] != nil:
                    "FlowPay Admin: Stream does not exist"
                FlowPay.streams[streamID]!.status == StreamStatus.active:
                    "FlowPay Admin: Stream is not active"
            }
            let balance = FlowPay.escrowVaults[streamID]?.balance ?? 0.0
            if balance > 0.0 {
                let refund <- FlowPay.escrowVaults[streamID]?.withdraw(amount: balance)!
                refundReceiver.deposit(from: <- refund)
            }
            FlowPay.streams[streamID]!.markCancelled()

            emit StreamCancelled(
                streamID: streamID,
                creator:  FlowPay.streams[streamID]!.creator,
                refunded: balance
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Initializer
    // ═══════════════════════════════════════════════════════════════

    init() {
        self.PLATFORM_FEE_PERCENT  = 1.0        // 1%
        self.MAX_RECIPIENTS        = 100
        self.SECONDS_PER_WEEK      = 604800.0   // 7 × 24 × 60 × 60
        self.SECONDS_PER_MONTH     = 2592000.0  // 30 × 24 × 60 × 60

        self.AdminStoragePath      = /storage/FlowPayAdmin
        self.AdminPublicPath       = /public/FlowPayAdmin

        self.nextStreamID           = 1
        self.streams                = {}
        self.creatorIndex           = {}
        self.escrowVaults           <- {}
        self.platformVault          <- (FlowToken.createEmptyVault(
            vaultType: Type<@FlowToken.Vault>()
        ) as! @FlowToken.Vault)

        self.totalStreamsCreated     = 0
        self.totalTokensDistributed = 0.0
        self.totalFeesCollected     = 0.0

        self.account.storage.save(<- create Admin(), to: self.AdminStoragePath)

        emit ContractInitialized()
    }
}
