//! Bisection logic for dispute resolution

use xlayer_core::{Hash, TraceLog};

/// Bisection manager
pub struct BisectionManager {
    /// Start block of the batch
    start_block: u64,
    /// End block of the batch
    end_block: u64,
    /// Current bisection range start
    current_start: u64,
    /// Current bisection range end
    current_end: u64,
    /// Trace log for looking up trace hashes
    trace_log: TraceLog,
    /// Is this manager for proposer or challenger
    is_proposer: bool,
}

impl BisectionManager {
    /// Create a new bisection manager
    pub fn new(
        start_block: u64,
        end_block: u64,
        trace_log: TraceLog,
        is_proposer: bool,
    ) -> Self {
        Self {
            start_block,
            end_block,
            current_start: start_block,
            current_end: end_block,
            trace_log,
            is_proposer,
        }
    }

    /// Get the midpoint block number
    pub fn get_midpoint(&self) -> u64 {
        (self.current_start + self.current_end) / 2
    }

    /// Get trace hash at a specific block
    pub fn get_trace_hash(&self, block_number: u64) -> Option<Hash> {
        self.trace_log.get_trace_at(block_number)
    }

    /// Process opponent's claim and decide response
    pub fn process_opponent_claim(
        &mut self,
        claimed_block: u64,
        claimed_trace: Hash,
    ) -> BisectionResponse {
        // Get our trace hash at the claimed block
        let our_trace = self.get_trace_hash(claimed_block);

        match our_trace {
            Some(trace) if trace == claimed_trace => {
                // We agree with the claim
                // Narrow range to second half
                self.current_start = claimed_block;
                
                if self.is_bisection_complete() {
                    BisectionResponse::Complete {
                        disputed_block: self.current_end,
                    }
                } else {
                    // We need to make a new claim
                    let mid = self.get_midpoint();
                    BisectionResponse::Agree {
                        our_mid_block: mid,
                        our_trace_hash: self.get_trace_hash(mid).unwrap_or([0u8; 32]),
                    }
                }
            }
            Some(_) | None => {
                // We disagree with the claim
                // Narrow range to first half
                self.current_end = claimed_block;
                
                if self.is_bisection_complete() {
                    BisectionResponse::Complete {
                        disputed_block: self.current_end,
                    }
                } else {
                    // Make a new claim at midpoint
                    let mid = self.get_midpoint();
                    BisectionResponse::Disagree {
                        our_mid_block: mid,
                        our_trace_hash: self.get_trace_hash(mid).unwrap_or([0u8; 32]),
                    }
                }
            }
        }
    }

    /// Check if bisection is complete (range narrowed to single block)
    pub fn is_bisection_complete(&self) -> bool {
        self.current_end - self.current_start <= 1
    }

    /// Get the disputed block (after bisection completes)
    pub fn get_disputed_block(&self) -> Option<u64> {
        if self.is_bisection_complete() {
            Some(self.current_end)
        } else {
            None
        }
    }

    /// Get current range
    pub fn get_range(&self) -> (u64, u64) {
        (self.current_start, self.current_end)
    }
}

/// Bisection response
#[derive(Debug, Clone)]
pub enum BisectionResponse {
    /// Agree with opponent's claim, provide our claim for the next round
    Agree {
        our_mid_block: u64,
        our_trace_hash: Hash,
    },
    /// Disagree with opponent's claim, provide our claim for the next round
    Disagree {
        our_mid_block: u64,
        our_trace_hash: Hash,
    },
    /// Bisection is complete, identified the disputed block
    Complete {
        disputed_block: u64,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use xlayer_core::trace::TraceEntry;

    fn create_test_trace_log() -> TraceLog {
        let mut log = TraceLog::new();
        for i in 0..1000 {
            log.add_entry(TraceEntry {
                block_number: i,
                block_hash: [i as u8; 32],
                state_hash: [(i + 1) as u8; 32],
                trace_hash: [(i + 2) as u8; 32],
            });
        }
        log
    }

    #[test]
    fn test_bisection_complete() {
        let trace_log = create_test_trace_log();
        let mut manager = BisectionManager::new(0, 1000, trace_log, true);

        // Simulate bisection rounds
        let mut round = 0;
        while !manager.is_bisection_complete() {
            let mid = manager.get_midpoint();
            // Simulate disagreement on all claims
            manager.current_end = mid;
            round += 1;
        }

        assert!(manager.is_bisection_complete());
        assert!(manager.get_disputed_block().is_some());
        assert!(round <= 10); // Should complete in ~10 rounds
    }
}
