// FlowPay.cdc
// ─────────────────────────────────────────────────────────────────────────────
// FlowPay – Native Cadence recurring payout contract for Flow blockchain.
//
// Architecture:
//   • PayoutSchedule resource  – held in creator's account storage (escrow + metadata)
//   • ScheduleCollection       – holds all schedules for one user
//   • FlowPayTransactionHandler – implements FlowTransactionScheduler.TransactionHandler
//     (same concept as Counter + CounterTransactionHandler learning contracts):
//     scheduler invokes the handler’s executeTransaction at scheduled times to run
//     payouts on-chain automatically.
// ─────────────────────────────────────────────────────────────────────────────

import "FlowToken"
import "FungibleToken"

access(all) contract FlowPay {

    // ─── Recipient types (multi-recipient support) ───────────────────────────
    access(all) struct RecipientEntry {
        access(all) let address: Address
        access(all) let amount:  UFix64

        init(address: Address, amount: UFix64) {
            self.address = address
            self.amount  = amount
        }
    }

    access(all) struct RecipientInfo {
        access(all) let address: Address
        access(all) let amount:  UFix64

        init(address: Address, amount: UFix64) {
            self.address = address
            self.amount  = amount
        }
    }

    // ─── Storage Paths ──────────────────────────────────────────────────────
    access(all) let ScheduleStoragePath:  StoragePath
    access(all) let SchedulePublicPath:   PublicPath
    access(all) let ManagerStoragePath:   StoragePath
    access(all) let ManagerPublicPath:    PublicPath

    // ─── Contract State ─────────────────────────────────────────────────────
    access(all) var totalSchedulesCreated: UInt64
    access(all) var totalPayoutsExecuted:  UInt64

    // ─── Events ─────────────────────────────────────────────────────────────
    access(all) event ScheduleCreated(
        id:               UInt64,
        creator:          Address,
        recipientCount:   UInt64,
        totalPerPayout:   UFix64,
        intervalSeconds:  UFix64,
        totalPayouts:     UInt64,
        label:            String
    )
    access(all) event PayoutExecuted(
        scheduleId:    UInt64,
        recipient:     Address,
        amount:        UFix64,
        payoutNumber:  UInt64,
        totalPayouts:  UInt64
    )
    access(all) event SchedulePaused(scheduleId: UInt64, creator: Address)
    access(all) event ScheduleResumed(scheduleId: UInt64, creator: Address)
    access(all) event ScheduleCancelled(scheduleId: UInt64, creator: Address, refunded: UFix64)
    access(all) event FundsToppedUp(scheduleId: UInt64, amount: UFix64)

    // ─── Entitlements ───────────────────────────────────────────────────────
    access(all) entitlement Owner
    access(all) entitlement Execute

    // ─── Status Enum ─────────────────────────────────────────────────────────
    access(all) enum Status: UInt8 {
        access(all) case Active
        access(all) case Paused
        access(all) case Completed
        access(all) case Cancelled
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PayoutSchedule Resource
    // ─────────────────────────────────────────────────────────────────────────
    access(all) resource PayoutSchedule {

        access(all) let id:               UInt64
        access(all) let creator:          Address
        access(all) let recipients:        [RecipientEntry]
        access(all) let totalPerPayout:   UFix64
        access(all) let intervalSeconds:  UFix64
        access(all) let totalPayouts:    UInt64
        access(all) var completedPayouts: UInt64
        access(all) var nextPayoutTime:   UFix64
        access(all) var status:           Status
        access(all) let label:            String

        access(self) var vault: @FlowToken.Vault

        init(
            id:              UInt64,
            creator:         Address,
            recipients:      [RecipientEntry],
            intervalSeconds: UFix64,
            totalPayouts:    UInt64,
            label:           String,
            vault:           @FlowToken.Vault
        ) {
            pre {
                recipients.length > 0 : "Must have at least 1 recipient"
                FlowPay.sumRecipientAmounts(recipients) > 0.0 : "Total per payout must be > 0"
                intervalSeconds >= 60.0 || totalPayouts == 1 : "Interval must be at least 60 seconds or single payout"
                totalPayouts > 0 : "Must have at least 1 payout"
                vault.balance >= FlowPay.sumRecipientAmounts(recipients) * UFix64(totalPayouts)
                    : "Vault balance insufficient for all payouts"
            }
            self.id               = id
            self.creator          = creator
            self.recipients       = recipients
            self.totalPerPayout   = FlowPay.sumRecipientAmounts(recipients)
            self.intervalSeconds  = intervalSeconds
            self.totalPayouts     = totalPayouts
            self.completedPayouts = 0
            self.nextPayoutTime   = getCurrentBlock().timestamp + (intervalSeconds > 0.0 ? intervalSeconds : 60.0)
            self.status           = Status.Active
            self.label            = label
            self.vault            <- vault
        }

        access(all) view fun getBalance(): UFix64 { return self.vault.balance }
        access(all) view fun remainingPayouts(): UInt64 { return self.totalPayouts - self.completedPayouts }
        access(all) view fun progressPercent(): UFix64 {
            if self.totalPayouts == 0 { return 0.0 }
            return UFix64(self.completedPayouts) / UFix64(self.totalPayouts) * 100.0
        }
        access(all) view fun isDue(): Bool {
            return self.status == Status.Active
                && getCurrentBlock().timestamp >= self.nextPayoutTime
                && self.completedPayouts < self.totalPayouts
        }

        access(Execute) fun executePayout(): Bool {
            pre {
                self.status == Status.Active : "Schedule is not active"
                getCurrentBlock().timestamp >= self.nextPayoutTime : "Payout not yet due"
                self.completedPayouts < self.totalPayouts : "All payouts completed"
                self.vault.balance >= self.totalPerPayout : "Insufficient escrow balance"
            }

            for entry in self.recipients {
                let payment <- self.vault.withdraw(amount: entry.amount) as! @FlowToken.Vault
                let recipientAccount = getAccount(entry.address)
                let receiverRef = recipientAccount.capabilities
                    .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                    ?? panic("Could not borrow FlowToken receiver for recipient: ".concat(entry.address.toString()))
                receiverRef.deposit(from: <-payment)
                emit PayoutExecuted(
                    scheduleId:   self.id,
                    recipient:    entry.address,
                    amount:       entry.amount,
                    payoutNumber: self.completedPayouts + 1,
                    totalPayouts: self.totalPayouts
                )
            }

            self.completedPayouts = self.completedPayouts + 1
            self.nextPayoutTime   = getCurrentBlock().timestamp + (if self.intervalSeconds > 0.0 { self.intervalSeconds } else { 60.0 })

            if self.completedPayouts >= self.totalPayouts {
                self.status = Status.Completed
                return false
            }
            return true
        }

        access(Owner) fun pause() {
            pre { self.status == Status.Active : "Schedule is not active" }
            self.status = Status.Paused
            emit SchedulePaused(scheduleId: self.id, creator: self.creator)
        }

        access(Owner) fun resume() {
            pre { self.status == Status.Paused : "Schedule is not paused" }
            self.status = Status.Active
            self.nextPayoutTime = getCurrentBlock().timestamp + (if self.intervalSeconds > 0.0 { self.intervalSeconds } else { 60.0 })
            emit ScheduleResumed(scheduleId: self.id, creator: self.creator)
        }

        access(Owner) fun cancel(): @FlowToken.Vault {
            pre {
                self.status == Status.Active || self.status == Status.Paused
                    : "Cannot cancel a completed or already-cancelled schedule"
            }
            self.status = Status.Cancelled
            let refund <- self.vault.withdraw(amount: self.vault.balance) as! @FlowToken.Vault
            emit ScheduleCancelled(
                scheduleId: self.id,
                creator:    self.creator,
                refunded:   refund.balance
            )
            return <-refund
        }

        access(all) fun topUp(funds: @FlowToken.Vault) {
            pre {
                self.status == Status.Active || self.status == Status.Paused
                    : "Cannot top up a completed or cancelled schedule"
                funds.balance > 0.0 : "Must deposit > 0 FLOW"
            }
            let amount = funds.balance
            self.vault.deposit(from: <-funds)
            emit FundsToppedUp(scheduleId: self.id, amount: amount)
        }

        destroy() {
            destroy self.vault
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ScheduleCollection
    // ─────────────────────────────────────────────────────────────────────────
    access(all) resource interface ScheduleCollectionPublic {
        access(all) view fun getIDs(): [UInt64]
        access(all) view fun getScheduleInfo(id: UInt64): ScheduleInfo?
        access(all) view fun getDueIDs(): [UInt64]
    }

    access(all) resource ScheduleCollection: ScheduleCollectionPublic {
        access(self) var schedules: @{UInt64: PayoutSchedule}

        init() { self.schedules <- {} }

        access(all) fun addSchedule(schedule: @PayoutSchedule) {
            let id = schedule.id
            self.schedules[id] <-! schedule
        }

        access(all) view fun getIDs(): [UInt64] { return self.schedules.keys }

        access(all) view fun getScheduleInfo(id: UInt64): ScheduleInfo? {
            if let s = &self.schedules[id] as &PayoutSchedule? {
                var recipientInfos: [FlowPay.RecipientInfo] = []
                for entry in s.recipients {
                    recipientInfos.append(FlowPay.RecipientInfo(address: entry.address, amount: entry.amount))
                }
                return ScheduleInfo(
                    id:               s.id,
                    creator:          s.creator,
                    recipients:       recipientInfos,
                    totalPerPayout:   s.totalPerPayout,
                    intervalSeconds:  s.intervalSeconds,
                    totalPayouts:     s.totalPayouts,
                    completedPayouts: s.completedPayouts,
                    nextPayoutTime:   s.nextPayoutTime,
                    balance:          s.getBalance(),
                    status:           s.status,
                    label:            s.label,
                    progress:         s.progressPercent(),
                    isDue:            s.isDue()
                )
            }
            return nil
        }

        access(all) view fun getDueIDs(): [UInt64] {
            let due: [UInt64] = []
            for id in self.schedules.keys {
                if let s = &self.schedules[id] as &PayoutSchedule? {
                    if s.isDue() { due.append(id) }
                }
            }
            return due
        }

        access(Owner) fun pause(id: UInt64) {
            let s = (&self.schedules[id] as auth(Owner) &PayoutSchedule?)
                ?? panic("Schedule not found: ".concat(id.toString()))
            s.pause()
        }

        access(Owner) fun resume(id: UInt64) {
            let s = (&self.schedules[id] as auth(Owner) &PayoutSchedule?)
                ?? panic("Schedule not found: ".concat(id.toString()))
            s.resume()
        }

        access(Owner) fun cancel(id: UInt64, creatorVaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault) {
            let s <- self.schedules.remove(key: id)
                ?? panic("Schedule not found: ".concat(id.toString()))
            let refund <- (s as auth(Owner) &PayoutSchedule).cancel()
            creatorVaultRef.deposit(from: <-refund)
            destroy s
        }

        access(Execute) fun executePayout(id: UInt64): Bool {
            let s = (&self.schedules[id] as auth(Execute) &PayoutSchedule?)
                ?? panic("Schedule not found: ".concat(id.toString()))
            return s.executePayout()
        }

        access(all) fun topUp(id: UInt64, funds: @FlowToken.Vault) {
            let s = (&self.schedules[id] as &PayoutSchedule?)
                ?? panic("Schedule not found: ".concat(id.toString()))
            s.topUp(funds: <-funds)
        }

        destroy() { destroy self.schedules }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ScheduleInfo struct
    // ─────────────────────────────────────────────────────────────────────────
    access(all) struct ScheduleInfo {
        access(all) let id:               UInt64
        access(all) let creator:          Address
        access(all) let recipients:       [RecipientInfo]
        access(all) let totalPerPayout:   UFix64
        access(all) let intervalSeconds:  UFix64
        access(all) let totalPayouts:     UInt64
        access(all) let completedPayouts: UInt64
        access(all) let nextPayoutTime:   UFix64
        access(all) let balance:          UFix64
        access(all) let status:           FlowPay.Status
        access(all) let label:            String
        access(all) let progress:         UFix64
        access(all) let isDue:            Bool

        init(
            id: UInt64, creator: Address, recipients: [RecipientInfo],
            totalPerPayout: UFix64, intervalSeconds: UFix64,
            totalPayouts: UInt64, completedPayouts: UInt64,
            nextPayoutTime: UFix64, balance: UFix64,
            status: FlowPay.Status, label: String,
            progress: UFix64, isDue: Bool
        ) {
            self.id = id
            self.creator = creator
            self.recipients = recipients
            self.totalPerPayout = totalPerPayout
            self.intervalSeconds = intervalSeconds
            self.totalPayouts = totalPayouts
            self.completedPayouts = completedPayouts
            self.nextPayoutTime = nextPayoutTime
            self.balance = balance
            self.status = status
            self.label = label
            self.progress = progress
            self.isDue = isDue
        }
    }

    access(all) fun createScheduleCollection(): @ScheduleCollection {
        return <- create ScheduleCollection()
    }

    access(all) fun sumRecipientAmounts(_ recipients: [RecipientEntry]): UFix64 {
        var total: UFix64 = 0.0
        for entry in recipients {
            total = total + entry.amount
        }
        return total
    }

    access(all) fun createSchedule(
        creator:         Address,
        recipients:      [RecipientEntry],
        intervalSeconds: UFix64,
        totalPayouts:    UInt64,
        label:           String,
        funds:           @FlowToken.Vault
    ): @PayoutSchedule {
        FlowPay.totalSchedulesCreated = FlowPay.totalSchedulesCreated + 1

        let schedule <- create PayoutSchedule(
            id:              FlowPay.totalSchedulesCreated,
            creator:         creator,
            recipients:      recipients,
            intervalSeconds: intervalSeconds,
            totalPayouts:    totalPayouts,
            label:           label,
            vault:           <-funds
        )

        emit ScheduleCreated(
            id:               schedule.id,
            creator:          creator,
            recipientCount:   UInt64(recipients.length),
            totalPerPayout:   FlowPay.sumRecipientAmounts(recipients),
            intervalSeconds:  intervalSeconds,
            totalPayouts:    totalPayouts,
            label:            label
        )

        return <-schedule
    }

    init() {
        self.ScheduleStoragePath = /storage/FlowPayScheduleCollection
        self.SchedulePublicPath  = /public/FlowPayScheduleCollection
        self.ManagerStoragePath  = /storage/FlowPayManager
        self.ManagerPublicPath   = /public/FlowPayManager
        self.totalSchedulesCreated = 0
        self.totalPayoutsExecuted  = 0
    }
}
