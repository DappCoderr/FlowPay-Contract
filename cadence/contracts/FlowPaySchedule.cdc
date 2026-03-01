// FlowPaySchedule.cdc
// ─────────────────────────────────────────────────────────────────────────────
// FlowPay Schedule – Recurrence types and interval helpers for FlowPay.
// Used by FlowPay to map UI recurrence (once, weekly, monthly) to on-chain
// interval seconds and labels.
// ─────────────────────────────────────────────────────────────────────────────

access(all) contract FlowPaySchedule {

    /// Recurrence type for a payout schedule (matches FlowPay UI)
    access(all) enum Recurrence: UInt8 {
        access(all) case Once    // single payout
        access(all) case Weekly  // every 7 days
        access(all) case Monthly // every ~30.44 days (2629800 seconds)
    }

    /// Minimum interval between payouts (60 seconds)
    access(all) let MinIntervalSeconds: UFix64

    /// Seconds in one week (7 * 24 * 3600)
    access(all) let WeeklyIntervalSeconds: UFix64

    /// Approximate seconds in one month (30.44 days)
    access(all) let MonthlyIntervalSeconds: UFix64

    /// Returns interval in seconds for the given recurrence.
    /// Once: returns 0 (single payout uses totalPayouts = 1, interval unused for next)
    access(all) fun intervalSecondsFor(recurrence: Recurrence): UFix64 {
        switch recurrence {
            case FlowPaySchedule.Recurrence.Once:
                return 0.0
            case FlowPaySchedule.Recurrence.Weekly:
                return self.WeeklyIntervalSeconds
            case FlowPaySchedule.Recurrence.Monthly:
                return self.MonthlyIntervalSeconds
        }
    }

    /// Human-readable label for recurrence
    access(all) fun labelFor(recurrence: Recurrence): String {
        switch recurrence {
            case FlowPaySchedule.Recurrence.Once:
                return "Once"
            case FlowPaySchedule.Recurrence.Weekly:
                return "Weekly"
            case FlowPaySchedule.Recurrence.Monthly:
                return "Monthly"
        }
    }

    init() {
        self.MinIntervalSeconds       = 60.0
        self.WeeklyIntervalSeconds    = 604800.0   // 7 * 24 * 3600
        self.MonthlyIntervalSeconds   = 2629800.0  // ~30.44 days
    }
}
