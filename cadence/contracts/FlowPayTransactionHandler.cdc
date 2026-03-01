// FlowPayTransactionHandler.cdc
// ─────────────────────────────────────────────────────────────────────────────
// Implements FlowTransactionScheduler.TransactionHandler for FlowPay (same
// pattern as the learning contracts Counter + CounterTransactionHandler).
//
// Flow native TransactionScheduler concept (from Counter/CounterTransactionHandler):
//   • A separate contract provides a Handler resource implementing
//     FlowTransactionScheduler.TransactionHandler.
//   • Handler has: executeTransaction(id, data), getViews(), resolveView(_).
//   • Scheduler calls executeTransaction when a scheduled time is reached;
//     getViews/resolveView tell the scheduler where the handler lives.
//
// FlowPay extension: executeTransaction receives PayoutCallData (creator, scheduleId),
// runs FlowPay.executePayout for that schedule, then re-schedules the next payout
// via FlowTransactionSchedulerUtils.Manager if more payouts remain.
// ─────────────────────────────────────────────────────────────────────────────

import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowPay"
import "FlowToken"
import "FungibleToken"

access(all) contract FlowPayTransactionHandler {

    access(all) let HandlerStoragePath: StoragePath
    access(all) let HandlerPublicPath:  PublicPath

    access(all) event HandlerExecuted(scheduleId: UInt64, creatorAddress: Address, nextScheduled: Bool)

    access(all) struct PayoutCallData {
        access(all) let creatorAddress: Address
        access(all) let scheduleId:     UInt64

        init(creatorAddress: Address, scheduleId: UInt64) {
            self.creatorAddress = creatorAddress
            self.scheduleId     = scheduleId
        }
    }

    /// Handler resource: same TransactionHandler interface as CounterTransactionHandler.Handler
    /// (executeTransaction + getViews + resolveView). FlowPay uses data: PayoutCallData and re-schedules.
    access(all) resource Handler: FlowTransactionScheduler.TransactionHandler {

        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let callData = data as? FlowPayTransactionHandler.PayoutCallData
                ?? panic("FlowPayTransactionHandler: missing or invalid PayoutCallData")

            let creatorAddress = callData.creatorAddress
            let scheduleId     = callData.scheduleId

            let creatorAccount = getAccount(creatorAddress)
            let collection = creatorAccount.capabilities
                .borrow<&{FlowPay.ScheduleCollectionPublic}>(FlowPay.SchedulePublicPath)
                ?? panic("Cannot borrow ScheduleCollection for: ".concat(creatorAddress.toString()))

            let info = collection.getScheduleInfo(id: scheduleId)
                ?? panic("Schedule not found: ".concat(scheduleId.toString()))

            if !info.isDue {
                return
            }

            let execCap = FlowPayTransactionHandler.executeCaps[creatorAddress]
                ?? panic("No Execute capability registered for: ".concat(creatorAddress.toString()))

            let execCollection = execCap.borrow()
                ?? panic("Stale Execute capability for: ".concat(creatorAddress.toString()))

            let hasMore = execCollection.executePayout(id: scheduleId)

            emit HandlerExecuted(
                scheduleId:     scheduleId,
                creatorAddress: creatorAddress,
                nextScheduled:  hasMore
            )

            if hasMore {
                FlowPayTransactionHandler.scheduleNextPayout(
                    creatorAddress: creatorAddress,
                    scheduleId:     scheduleId,
                    intervalSeconds: info.intervalSeconds
                )
            }
        }

        access(all) view fun getViews(): [Type] {
            return [Type<StoragePath>(), Type<PublicPath>()]
        }

        access(all) fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<StoragePath>(): return FlowPayTransactionHandler.HandlerStoragePath
                case Type<PublicPath>():  return FlowPayTransactionHandler.HandlerPublicPath
                default: return nil
            }
        }
    }

    access(self) var executeCaps: {Address: Capability<auth(FlowPay.Execute) &FlowPay.ScheduleCollection>}

    access(all) fun registerExecuteCapability(
        creator: Address,
        cap: Capability<auth(FlowPay.Execute) &FlowPay.ScheduleCollection>
    ) {
        pre { cap.check() : "Invalid Execute capability" }
        FlowPayTransactionHandler.executeCaps[creator] = cap
    }

    access(contract) fun scheduleNextPayout(
        creatorAddress:  Address,
        scheduleId:      UInt64,
        intervalSeconds: UFix64
    ) {
        let manager = FlowPayTransactionHandler.account.storage
            .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                from: FlowTransactionSchedulerUtils.managerStoragePath
            ) ?? panic("FlowPayTransactionHandler: Manager not found in contract account storage")

        let future = getCurrentBlock().timestamp + intervalSeconds

        let est = FlowTransactionScheduler.estimate(
            data: FlowPayTransactionHandler.PayoutCallData(
                creatorAddress: creatorAddress,
                scheduleId:     scheduleId
            ),
            timestamp:         future,
            priority:          FlowTransactionScheduler.Priority.Medium,
            executionEffort:   2000
        )

        let vaultRef = FlowPayTransactionHandler.account.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("FlowPayTransactionHandler: No FlowToken vault in contract account")

        let fees <- vaultRef.withdraw(amount: est.flowFee ?? 0.0) as! @FlowToken.Vault

        let handlerTypeIdentifier = manager.getHandlerTypes().keys[0]!

        manager.scheduleByHandler(
            handlerTypeIdentifier: handlerTypeIdentifier,
            handlerUUID:           nil,
            data:                  FlowPayTransactionHandler.PayoutCallData(
                creatorAddress: creatorAddress,
                scheduleId:     scheduleId
            ),
            timestamp:             future,
            priority:              FlowTransactionScheduler.Priority.Medium,
            executionEffort:       2000,
            fees:                  <-fees
        )
    }

    access(all) fun createHandler(): @Handler {
        return <- create Handler()
    }

    init() {
        self.HandlerStoragePath = /storage/FlowPayTransactionHandler
        self.HandlerPublicPath  = /public/FlowPayTransactionHandler
        self.executeCaps        = {}

        let handler <- create Handler()
        self.account.storage.save(<-handler, to: self.HandlerStoragePath)

        let publicCap = self.account.capabilities.storage
            .issue<&{FlowTransactionScheduler.TransactionHandler}>(self.HandlerStoragePath)
        self.account.capabilities.publish(publicCap, at: self.HandlerPublicPath)
    }
}
