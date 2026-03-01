// GetFlowPayContractStats.cdc
// Returns global FlowPay contract stats: totalSchedulesCreated, totalPayoutsExecuted.

import "FlowPay"

access(all) struct FlowPayStats {
    access(all) let totalSchedulesCreated: UInt64
    access(all) let totalPayoutsExecuted:  UInt64

    init(totalSchedulesCreated: UInt64, totalPayoutsExecuted: UInt64) {
        self.totalSchedulesCreated = totalSchedulesCreated
        self.totalPayoutsExecuted  = totalPayoutsExecuted
    }
}

access(all) fun main(): GetFlowPayContractStats.FlowPayStats {
    return GetFlowPayContractStats.FlowPayStats(
        totalSchedulesCreated: FlowPay.totalSchedulesCreated,
        totalPayoutsExecuted:  FlowPay.totalPayoutsExecuted
    )
}
