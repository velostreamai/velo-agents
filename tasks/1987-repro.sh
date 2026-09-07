#!/usr/bin/env bash
# #1987 Stage-1 reproduction harness.
#
# Emits the exact post-JOIN post-WHERE column layout the batch stream-stream
# JOIN fast path produces for the issue's query, as a machine-greppable line:
#
#   REPRO-COLUMN-LIST: <semicolon-separated canonical column names>
#   REPRO-VERDICT: UNPROJECTED | PROJECTED
#
# Read-only with respect to src/ — it is a NEW test file, unregistered in
# tests/mod.rs (so it is never compiled by any gate), and is executed once via
# `cargo test --test repro_1987_columns` with a temporary registration-free
# harness file. The file is deleted after the run by the caller.
#
# Run from the worktree root:
#   bash .agents/tasks/1987-repro.sh
set -euo pipefail

HARNESS="tests/repro_1987_columns.rs"

cat > "$HARNESS" <<'EOF'
//! #1987 Stage-1 reproduction — NOT part of the suite. Emitted and removed
//! by .agents/tasks/1987-repro.sh; never registered in tests/mod.rs.

use std::sync::Arc;
use velostream::velostream::sql::execution::internal::PrimedQuery;
use velostream::velostream::sql::execution::types::{FieldName, FieldValue};
use velostream::velostream::sql::execution::{StreamExecutionEngine, StreamRecord};
use velostream::velostream::sql::parser::StreamingSqlParser;
use velostream::velostream::sql::plan::build_plan_no_gate;

fn fn_name(s: &str) -> FieldName {
    Arc::from(s)
}

fn single_row(fields: Vec<(&str, FieldValue)>) -> StreamRecord {
    let rows = vec![
        fields
            .into_iter()
            .map(|(k, v)| (fn_name(k), v))
            .collect::<Vec<_>>(),
    ];
    StreamRecord::from_rows(rows, None, vec![0], vec![0], None, None, None).expect("single_row")
}

fn probe_batch(rows: Vec<Vec<(&str, FieldValue)>>) -> StreamRecord {
    let n = rows.len();
    let mapped: Vec<Vec<(FieldName, FieldValue)>> = rows
        .into_iter()
        .map(|r| r.into_iter().map(|(k, v)| (fn_name(k), v)).collect())
        .collect();
    let ts = vec![0i64; n];
    let off = vec![0i64; n];
    StreamRecord::from_rows(mapped, None, ts, off, None, None, None).expect("probe_batch")
}

#[test]
fn repro_1987_groupby_join_batch() {
    // Reasoned prediction from the dispatch gate at select.rs:848
    // (row_count>1 && joins.is_some() && window.is_none() — no group_by check)
    // plus find_join_plan_node's descent through Aggregate: the batch stream-
    // stream arm should intercept a GROUP BY + JOIN query on N>1 input and
    // return the joined batch UNGROUPED. Measure it.
    let sql = "SELECT a.category, COUNT(*) AS cnt FROM auction a \
               JOIN person r ON a.seller = r.person_id \
               GROUP BY a.category";

    let build_records = vec![
        single_row(vec![
            ("person_id", FieldValue::Integer(1)),
            ("tier", FieldValue::String(Arc::from("gold"))),
        ]),
        single_row(vec![
            ("person_id", FieldValue::Integer(2)),
            ("tier", FieldValue::String(Arc::from("silver"))),
        ]),
    ];
    let parser = StreamingSqlParser::new();
    let query = parser.parse(sql).expect("parse");
    let mut engine = StreamExecutionEngine::new();
    let plan = build_plan_no_gate(&query, &|_| None);
    let mut pq = PrimedQuery::builder(query.clone()).plan(plan).build();
    pq.processor_context
        .io_mut()
        .add_data_source("person".to_string(), build_records);

    let probe = probe_batch(vec![
        vec![
            ("auction_id", FieldValue::Integer(101)),
            ("seller", FieldValue::Integer(1)),
            ("category", FieldValue::Integer(10)),
        ],
        vec![
            ("auction_id", FieldValue::Integer(102)),
            ("seller", FieldValue::Integer(1)),
            ("category", FieldValue::Integer(10)),
        ],
        vec![
            ("auction_id", FieldValue::Integer(103)),
            ("seller", FieldValue::Integer(2)),
            ("category", FieldValue::Integer(5)),
        ],
    ]);

    let (results, errs) = engine.execute_pq(&mut pq, &probe).expect("execute");

    let counts: Vec<usize> = results.iter().map(|r| r.row_count()).collect();
    let err_count = errs.len();
    for (idx, e) in errs.iter().take(2) {
        println!("GB-ROW-ERROR[{}]: {}", idx, e);
    }
    println!("GB-RESULT-RECORDS: {} counts={:?} row_errors={}", results.len(), counts, err_count);

    let rec = match results.iter().find(|r| r.row_count() > 0) {
        Some(r) => r,
        None => {
            println!("GB-VERDICT: EMPTY-OUTPUT (no non-empty record; dispatch never emitted)");
            return;
        }
    };
    let names: Vec<String> = rec
        .batch
        .schema()
        .fields()
        .iter()
        .map(|f| f.name().clone())
        .collect();
    let data: Vec<String> = names
        .iter()
        .filter(|n| !n.starts_with('_'))
        .cloned()
        .collect();

    println!("\nGB-COLUMN-LIST: {}", data.join(";"));
    println!("GB-ROW-COUNT: {}", rec.row_count());
    // Ungrouped = one row per JOIN match (3); grouped = one row per category (2).
    println!(
        "GB-VERDICT: {}",
        if rec.row_count() == 3 { "UNGROUPED" } else { "GROUPED-OR-OTHER" }
    );
}

#[test]
fn repro_1987_limit_join_batch() {
    // Same gate analysis: LIMIT sits above the Join in the plan
    // (Project { Limit { Join } }); find_join_plan_node descends Limit.
    // Prediction: the arm returns all 3 matched rows — LIMIT never applied,
    // ctx.limit_remaining never decremented.
    let sql = "SELECT a.auction_id, r.tier FROM auction a \
               JOIN person r ON a.seller = r.person_id \
               LIMIT 2";

    let build_records = vec![single_row(vec![
        ("person_id", FieldValue::Integer(1)),
        ("tier", FieldValue::String(Arc::from("gold"))),
    ])];
    let parser = StreamingSqlParser::new();
    let query = parser.parse(sql).expect("parse");
    let mut engine = StreamExecutionEngine::new();
    let plan = build_plan_no_gate(&query, &|_| None);
    let mut pq = PrimedQuery::builder(query.clone()).plan(plan).build();
    pq.processor_context
        .io_mut()
        .add_data_source("person".to_string(), build_records);

    let probe = probe_batch(vec![
        vec![
            ("auction_id", FieldValue::Integer(101)),
            ("seller", FieldValue::Integer(1)),
        ],
        vec![
            ("auction_id", FieldValue::Integer(102)),
            ("seller", FieldValue::Integer(1)),
        ],
        vec![
            ("auction_id", FieldValue::Integer(103)),
            ("seller", FieldValue::Integer(1)),
        ],
    ]);

    let (results, _errs) = engine.execute_pq(&mut pq, &probe).expect("execute");

    let total: usize = results.iter().map(|r| r.row_count()).sum();
    println!("\nLIM-ROW-COUNT: {}", total);
    println!(
        "LIM-VERDICT: {}",
        if total == 2 { "LIMITED" } else { "LIMIT-DROPPED-OR-OTHER" }
    );
}

#[test]
fn repro_1987_unprojected_join_columns() {
    let sql = "SELECT a.auction_id, a.category, r.tier FROM auction a \
               JOIN person r ON a.seller = r.person_id \
               WHERE a.category = 10";

    let build_records = vec![single_row(vec![
        ("person_id", FieldValue::Integer(1)),
        ("tier", FieldValue::String(Arc::from("gold"))),
    ])];
    let parser = StreamingSqlParser::new();
    let query = parser.parse(sql).expect("parse");
    let mut engine = StreamExecutionEngine::new();
    let plan = build_plan_no_gate(&query, &|_| None);
    let mut pq = PrimedQuery::builder(query.clone()).plan(plan).build();
    pq.processor_context
        .io_mut()
        .add_data_source("person".to_string(), build_records);

    let probe = probe_batch(vec![
        vec![
            ("auction_id", FieldValue::Integer(101)),
            ("seller", FieldValue::Integer(1)),
            ("category", FieldValue::Integer(10)),
        ],
        vec![
            ("auction_id", FieldValue::Integer(102)),
            ("seller", FieldValue::Integer(1)),
            ("category", FieldValue::Integer(5)),
        ],
        vec![
            ("auction_id", FieldValue::Integer(103)),
            ("seller", FieldValue::Integer(1)),
            ("category", FieldValue::Integer(10)),
        ],
    ]);

    let (results, _errs) = engine
        .execute_pq(&mut pq, &probe)
        .expect("execute must not error");

    let rec = results
        .iter()
        .find(|r| r.row_count() > 0)
        .expect("expected a non-empty output record");

    let mut names: Vec<String> = rec.batch.schema().fields().iter().map(|f| f.name().clone()).collect();
    let sys: Vec<String> = names
        .iter()
        .filter(|n| n.starts_with('_'))
        .cloned()
        .collect();
    names.retain(|n| !n.starts_with('_'));

    let first_row = rec.iter_rows().next().expect("at least one row");
    let mut data_names: Vec<String> = first_row.data_field_names().iter().map(|k| k.to_string()).collect();
    data_names.sort();

    println!("\nREPRO-COLUMN-LIST: {}", names.join(";"));
    println!("REPRO-DATA-FIELDS-ROW0: {}", data_names.join(";"));
    println!("REPRO-SYS-COLS: {}", sys.join(";"));
    println!("REPRO-ROW-COUNT: {}", rec.row_count());

    let selected = ["a.auction_id", "a.category", "r.tier"];
    let unprojected = names.len() != selected.len()
        || names.iter().any(|n| !selected.contains(&n.as_str()));
    println!(
        "REPRO-VERDICT: {}",
        if unprojected { "UNPROJECTED" } else { "PROJECTED" }
    );
}
EOF

echo "--- building + running repro (cargo test --test repro_1987_columns) ---"
cargo test --no-default-features --test repro_1987_columns -- --nocapture --exact repro_1987_columns::repro_1987_columns 2>&1 | tee /tmp/1987-repro-run.log
STATUS=${PIPESTATUS[0]}
rm -f "$HARNESS"
exit "$STATUS"
