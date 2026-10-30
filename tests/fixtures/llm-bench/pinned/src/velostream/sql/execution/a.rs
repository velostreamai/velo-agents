// Fixture for tests/test_llm_bench.sh: a small Rust tree in the shape of the directory the bench reads (src/velostream/sql/execution).
// Velostream is a private repository that a CI runner cannot clone, and what is under test is the bench's prompt builder, not
// Velostream: any .rs files at a pinned commit do. Non-ASCII on purpose: naïve résumé — ✓

pub struct RecordBatchWindow {
    rows: Vec<i64>,
}

impl RecordBatchWindow {
    pub fn new(rows: Vec<i64>) -> Self {
        Self { rows }
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }
}
