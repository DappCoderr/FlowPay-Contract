// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                                                                           ║
// ║   FlowPayScheduler.cdc                                                    ║
// ║   Autonomous Execution Handler for FlowTransactionScheduler               ║
// ║   Cadence 1.0 · Flow Blockchain                                            ║
// ║                                                                           ║
// ║   This contract bridges FlowPay streams to Flow's native                  ║
// ║   FlowTransactionScheduler protocol. Each stream creator stores           ║
// ║   one Handler resource in their account. The Flow protocol                ║
// ║   calls Handler.executeTransaction() at the scheduled timestamp          ║
// ║   with zero external triggers, bots, or keepers.                         ║
// ║                                                                           ║
// ║   Integration flow per user:                                              ║
// ║     1. init_scheduler_handler.cdc   — one-time account setup             ║
// ║     2. create_stream.cdc            — create stream + escrow             ║
// ║     3. schedule_stream.cdc          — register with Flow scheduler       ║
// ║        ↓                                                                  ║
// ║        Flow protocol calls Handler.executeTransaction(streamID)           ║
// ║        at the exact scheduled timestamp autonomously                      ║
// ║                                                                           ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

import FlowTransactionScheduler      from "FlowTransactionScheduler"
import FlowTransactionSchedulerUtils from "FlowTransactionSchedulerUtils"
import MetadataViews                  from "MetadataViews"
import FlowPay                        from "./FlowPay.cdc"

access(all) contract FlowPayScheduler {

    // ═══════════════════════════════════════════════════════════════
    // MARK: Storage Paths
    // ═══════════════════════════════════════════════════════════════

    /// Where each user stores their Handler resource
    access(all) let HandlerStoragePath: StoragePath

    /// Public capability path for metadata queries
    access(all) let HandlerPublicPath: PublicPath

    // ═══════════════════════════════════════════════════════════════
    // MARK: Events
    // ═══════════════════════════════════════════════════════════════

    access(all) event HandlerInitialised(owner: Address)

    access(all) event ScheduledExecutionTriggered(
        streamID:       UInt64,
        scheduledTxID:  UInt64,
        owner:          Address,
        cycleNumber:    UInt64
    )

    access(all) event ScheduledExecutionSkipped(
        streamID: UInt64,
        reason:   String
    )

    // ═══════════════════════════════════════════════════════════════
    // MARK: Handler Resource
    // ═══════════════════════════════════════════════════════════════

    /// Handler implements FlowTransactionScheduler.TransactionHandler.
    ///
    /// The Flow protocol calls executeTransaction(id, data) when the
    /// scheduled block timestamp arrives. `data` must be the UInt64
    /// streamID that was provided when scheduling via schedule_stream.cdc.
    ///
    /// One Handler serves one account. Multiple streams can route through
    /// the same Handler — the streamID distinguishes each call.
    access(all) resource Handler: FlowTransactionScheduler.TransactionHandler {

        /// The account address that owns this Handler
        access(all) let owner: Address

        /// Total number of stream executions routed through this handler
        access(all) var totalExecutions: UInt64

        init(owner: Address) {
            self.owner           = owner
            self.totalExecutions = 0
        }

        // ── Core callback — invoked by the Flow protocol ──────────

        access(FlowTransactionScheduler.Execute)
        fun executeTransaction(id: UInt64, data: AnyStruct?) {

            // Decode streamID from data parameter
            let streamID = data as? UInt64
                ?? panic(
                    "FlowPayScheduler: executeTransaction data must be a UInt64 streamID. "
                    .concat("Received type: ").concat(data.getType().identifier)
                )

            // Guard: verify stream still exists and is active
            guard let streamInfo = FlowPay.getStream(streamID: streamID) else {
                emit ScheduledExecutionSkipped(
                    streamID: streamID,
                    reason:   "Stream not found"
                )
                return
            }

            if streamInfo.status != FlowPay.StreamStatus.active {
                emit ScheduledExecutionSkipped(
                    streamID: streamID,
                    reason:   "Stream is not active (status: "
                        .concat(streamInfo.status.rawValue.toString()).concat(")")
                )
                return
            }

            // Delegate to FlowPay core — all validation happens there
            FlowPay.executeStream(streamID: streamID, executor: self.owner)

            self.totalExecutions = self.totalExecutions + 1

            emit ScheduledExecutionTriggered(
                streamID:      streamID,
                scheduledTxID: id,
                owner:         self.owner,
                cycleNumber:   self.totalExecutions
            )
        }

        // ── MetadataViews compliance ──────────────────────────────

        access(all) view fun getViews(): [Type] {
            return [
                Type<StoragePath>(),
                Type<PublicPath>(),
                Type<MetadataViews.Display>()
            ]
        }

        access(all) fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<StoragePath>():
                    return FlowPayScheduler.HandlerStoragePath
                case Type<PublicPath>():
                    return FlowPayScheduler.HandlerPublicPath
                case Type<MetadataViews.Display>():
                    return MetadataViews.Display(
                        name:        "FlowPay Scheduler Handler",
                        description: "Autonomous payment stream executor via FlowTransactionScheduler",
                        thumbnail:   MetadataViews.HTTPFile(url: "https://flowpay.io/icon.png")
                    )
                default:
                    return nil
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Factory
    // ═══════════════════════════════════════════════════════════════

    /// Create a new Handler for the given owner address.
    /// Called once per user by init_scheduler_handler.cdc.
    access(all) fun createHandler(owner: Address): @Handler {
        emit HandlerInitialised(owner: owner)
        return <- create Handler(owner: owner)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: Initializer
    // ═══════════════════════════════════════════════════════════════

    init() {
        self.HandlerStoragePath = /storage/FlowPaySchedulerHandler
        self.HandlerPublicPath  = /public/FlowPaySchedulerHandler
    }
}
