// Fixture for tests/test_ast_grep_tool.py: a small Rust tree in the shape of a Velostream source directory. The tool under
// test is the ast_grep wrapper, not Velostream, so what matters here is only that the syntax the checks look for is present
// (a `&self` method signature with a return type, as a trait declares it; a `.len()` call) and the syntax they must NOT find
// (a struct named in the zero-match check) is not.

pub trait Processor {
    fn name(&self) -> &str;
    fn batch_size(&self) -> usize;
}

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

    pub fn is_empty(&self) -> bool {
        self.rows.len() == 0
    }

    pub fn first(&self) -> Option<i64> {
        self.rows.first().copied()
    }
}
