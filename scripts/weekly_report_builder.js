/**
 * Weekly Executive Report Builder
 * ================================
 *
 * Queries the email analytics cube and assembles a formatted Word document
 * (.docx) summarizing performance over a specified date window. Designed for
 * unattended execution — point at the database, specify the window, get a
 * report file.
 *
 * Architecture:
 *   1. Connect to the Postgres database hosting the cube view.
 *   2. Run reconciliation checks (see sql/reconciliation.sql). If any fail,
 *      abort — do not publish numbers that don't reconcile.
 *   3. Execute the report's analytical queries against the cube.
 *   4. Assemble the queried data into structured docx elements (headers,
 *      paragraphs, tables, callout notes).
 *   5. Write the assembled document to disk.
 *
 * Usage:
 *   node weekly_report_builder.js --start 2025-05-11 --end 2025-06-01 \
 *                                  --output /path/to/output.docx
 *
 * Dependencies:
 *   - pg          (Postgres client)
 *   - docx        (Word document generation)
 *   - dotenv      (environment configuration)
 *   - yargs       (CLI argument parsing)
 *
 * This file is a sanitized template — production credentials and any
 * client-specific content have been removed.
 */

const { Pool } = require('pg');
const {
  Document,
  Packer,
  Paragraph,
  TextRun,
  HeadingLevel,
  Table,
  TableRow,
  TableCell,
  WidthType,
  AlignmentType,
  BorderStyle,
} = require('docx');
const fs = require('fs');
const yargs = require('yargs');
require('dotenv').config();


// ============================================================================
// Configuration
// ============================================================================

const COLORS = {
  ink:      '1A1A1A',
  body:     '333333',
  muted:    '888888',
  accent:   '0B5394',
  good:     '38761D',
  warn:     'B45309',
  bad:      'A61C00',
  bandAlt:  'F5F5F5',
};

const FONT = 'Helvetica Neue';

const REQUIRED_ENV_VARS = ['DATABASE_URL'];


// ============================================================================
// CLI argument parsing
// ============================================================================

const argv = yargs
  .option('start', {
    type: 'string',
    demandOption: true,
    describe: 'Start date for the analysis window (YYYY-MM-DD)',
  })
  .option('end', {
    type: 'string',
    demandOption: true,
    describe: 'End date for the analysis window (YYYY-MM-DD)',
  })
  .option('output', {
    type: 'string',
    default: './weekly_report.docx',
    describe: 'Output file path for the generated docx',
  })
  .option('skip-reconciliation', {
    type: 'boolean',
    default: false,
    describe: 'Skip reconciliation checks (NOT recommended for production)',
  })
  .help()
  .argv;


// ============================================================================
// Database utilities
// ============================================================================

function createDbPool() {
  for (const v of REQUIRED_ENV_VARS) {
    if (!process.env[v]) {
      throw new Error(`Missing required environment variable: ${v}`);
    }
  }

  return new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 5,
    idleTimeoutMillis: 30000,
  });
}

async function queryRows(pool, sql, params = []) {
  const res = await pool.query(sql, params);
  return res.rows;
}


// ============================================================================
// Reconciliation gate — fail fast if numbers don't add up
// ============================================================================

async function runReconciliationChecks(pool) {
  console.log('Running reconciliation checks...');

  // In production this would invoke the queries from sql/reconciliation.sql.
  // Each check returns 0 rows on pass, N rows on fail. We abort if any fail.
  const checks = [
    {
      name: 'Total sends reconciliation',
      sql: `
        WITH cube_t AS (SELECT SUM(sends) AS s FROM analytics.email_analytics_cube
                        WHERE send_week BETWEEN $1 AND $2),
             src_t  AS (SELECT COUNT(*) AS s FROM email_send_events
                        WHERE is_warmup = FALSE AND is_internal_test = FALSE
                          AND send_status = 'sent'
                          AND send_date BETWEEN $1 AND $2)
        SELECT cube_t.s AS cube_sends, src_t.s AS source_sends
        FROM cube_t, src_t
        WHERE cube_t.s != src_t.s
      `,
    },
    {
      name: 'Cohort split leakage',
      sql: `
        WITH t AS (
          SELECT SUM(CASE WHEN cohort_type='intent' THEN sends ELSE 0 END) AS i,
                 SUM(CASE WHEN cohort_type='prospecting' THEN sends ELSE 0 END) AS p,
                 SUM(sends) AS total
          FROM analytics.email_analytics_cube
          WHERE send_week BETWEEN $1 AND $2
        )
        SELECT * FROM t WHERE (i + p) != total
      `,
    },
    // Additional checks defined in sql/reconciliation.sql ...
  ];

  for (const check of checks) {
    const rows = await queryRows(pool, check.sql, [argv.start, argv.end]);
    if (rows.length > 0) {
      console.error(`  FAIL: ${check.name}`);
      console.error('  Details:', rows);
      throw new Error(`Reconciliation failed: ${check.name}`);
    }
    console.log(`  PASS: ${check.name}`);
  }
}


// ============================================================================
// Analytical queries — these feed each section of the report
// ============================================================================

async function getPortfolioSnapshot(pool) {
  return queryRows(pool, `
    SELECT
      SUM(sends) AS sends,
      SUM(human_replies) AS hr,
      SUM(opportunities) AS opps,
      SUM(bounces) AS bounces,
      ROUND(100.0 * SUM(human_replies)::numeric / NULLIF(SUM(sends), 0), 3) AS hrr_pct,
      ROUND(100.0 * SUM(opportunities)::numeric / NULLIF(SUM(sends), 0), 4) AS opp_rate_pct
    FROM analytics.email_analytics_cube
    WHERE send_week BETWEEN $1 AND $2
  `, [argv.start, argv.end]);
}

async function getCohortSplit(pool) {
  return queryRows(pool, `
    SELECT
      cohort_type,
      SUM(sends) AS sends,
      ROUND(100.0 * SUM(human_replies)::numeric / NULLIF(SUM(sends), 0), 3) AS hrr_pct,
      ROUND(100.0 * SUM(opportunities)::numeric / NULLIF(SUM(sends), 0), 4) AS opp_rate_pct,
      CASE WHEN SUM(opportunities) > 0
           THEN ROUND(SUM(sends)::numeric / SUM(opportunities), 0)
      END AS emails_per_opp
    FROM analytics.email_analytics_cube
    WHERE send_week BETWEEN $1 AND $2
    GROUP BY cohort_type
    ORDER BY cohort_type
  `, [argv.start, argv.end]);
}

async function getWeeklyTrend(pool) {
  return queryRows(pool, `
    SELECT
      cohort_type,
      send_week,
      SUM(sends) AS sends,
      SUM(human_replies) AS hr,
      ROUND(100.0 * SUM(human_replies)::numeric / NULLIF(SUM(sends), 0), 3) AS hrr_pct,
      ROUND(100.0 * SUM(opportunities)::numeric / NULLIF(SUM(sends), 0), 4) AS opp_rate_pct
    FROM analytics.email_analytics_cube
    WHERE send_week BETWEEN $1 AND $2
    GROUP BY cohort_type, send_week
    ORDER BY cohort_type, send_week
  `, [argv.start, argv.end]);
}

// Additional query functions follow the same pattern:
//   async function getSenderEspPerformance(pool) { ... }
//   async function getSourceBreakdown(pool, cohort) { ... }
//   async function getKillerCombos(pool) { ... }
//   async function getRecipientClassBehavior(pool) { ... }
//   async function getIndustryHierarchy(pool) { ... }
// (omitted in this sanitized template for brevity)


// ============================================================================
// Document element builders — reusable docx primitives
// ============================================================================

function heading(text, level = HeadingLevel.HEADING_1) {
  return new Paragraph({
    heading: level,
    children: [new TextRun({ text, font: FONT, color: COLORS.ink, bold: true })],
    spacing: { before: 200, after: 100 },
  });
}

function paragraph(text, opts = {}) {
  return new Paragraph({
    children: [new TextRun({
      text,
      font: FONT,
      color: opts.color || COLORS.body,
      bold: opts.bold || false,
      italics: opts.italic || false,
      size: opts.size || 22,
    })],
    spacing: { after: opts.after || 100 },
    alignment: opts.align || AlignmentType.LEFT,
  });
}

function headerCell(text, width) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    shading: { fill: COLORS.accent },
    children: [new Paragraph({
      children: [new TextRun({
        text, font: FONT, bold: true, color: 'FFFFFF', size: 20,
      })],
    })],
  });
}

function dataCell(text, width, opts = {}) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    shading: opts.fill ? { fill: opts.fill } : undefined,
    children: [new Paragraph({
      alignment: opts.align || AlignmentType.LEFT,
      children: [new TextRun({
        text: String(text),
        font: FONT,
        bold: opts.bold || false,
        color: opts.color || COLORS.body,
        size: opts.size || 20,
      })],
    })],
  });
}


// ============================================================================
// Section builders — one per major section of the report
// ============================================================================

function buildPortfolioSnapshotSection(snapshot) {
  const s = snapshot[0];
  const widths = [3000, 3000, 3360];

  return [
    heading('Portfolio Snapshot'),
    new Table({
      width: { size: 9360, type: WidthType.DXA },
      columnWidths: widths,
      rows: [
        new TableRow({
          tableHeader: true,
          children: [
            headerCell('Metric', widths[0]),
            headerCell('Volume', widths[1]),
            headerCell('Portfolio rate', widths[2]),
          ],
        }),
        new TableRow({ children: [
          dataCell('Sends', widths[0]),
          dataCell(s.sends.toLocaleString(), widths[1], { align: AlignmentType.RIGHT }),
          dataCell('—', widths[2], { align: AlignmentType.CENTER }),
        ]}),
        new TableRow({ children: [
          dataCell('Human replies', widths[0], { fill: COLORS.bandAlt }),
          dataCell(s.hr.toLocaleString(), widths[1], { align: AlignmentType.RIGHT, fill: COLORS.bandAlt }),
          dataCell(`HRR ${s.hrr_pct}%`, widths[2], { align: AlignmentType.CENTER, fill: COLORS.bandAlt, bold: true }),
        ]}),
        new TableRow({ children: [
          dataCell('Opportunities', widths[0]),
          dataCell(s.opps.toLocaleString(), widths[1], { align: AlignmentType.RIGHT }),
          dataCell(`Opp Rate ${s.opp_rate_pct}%`, widths[2], { align: AlignmentType.CENTER, bold: true }),
        ]}),
      ],
    }),
  ];
}

function buildCohortSplitSection(cohortData) {
  const widths = [2000, 2000, 1800, 1800, 1760];
  const rows = [
    new TableRow({
      tableHeader: true,
      children: [
        headerCell('Cohort', widths[0]),
        headerCell('Sends', widths[1]),
        headerCell('HRR', widths[2]),
        headerCell('Opp Rate', widths[3]),
        headerCell('Emails / Opp', widths[4]),
      ],
    }),
  ];

  for (const c of cohortData) {
    rows.push(new TableRow({ children: [
      dataCell(c.cohort_type, widths[0], { bold: true }),
      dataCell(c.sends.toLocaleString(), widths[1], { align: AlignmentType.RIGHT }),
      dataCell(`${c.hrr_pct}%`, widths[2], { align: AlignmentType.CENTER, bold: true }),
      dataCell(`${c.opp_rate_pct}%`, widths[3], { align: AlignmentType.CENTER, bold: true }),
      dataCell(c.emails_per_opp != null ? c.emails_per_opp.toLocaleString() : '—',
               widths[4], { align: AlignmentType.CENTER, bold: true }),
    ]}));
  }

  return [
    heading('Cohort split', HeadingLevel.HEADING_2),
    new Table({ width: { size: 9360, type: WidthType.DXA }, columnWidths: widths, rows }),
  ];
}

// Additional section builders follow the same pattern:
//   buildWeeklyTrendSection
//   buildSenderEspSection
//   buildSourceBreakdownSection
//   buildKillerCombosSection
//   buildPatternsFoundSection
//   buildDecisionsSection
//   buildGlossarySection


// ============================================================================
// Main orchestration
// ============================================================================

async function buildReport() {
  console.log(`Building weekly report for window: ${argv.start} → ${argv.end}`);

  const pool = createDbPool();

  try {
    // Step 1: Reconciliation gate
    if (!argv['skip-reconciliation']) {
      await runReconciliationChecks(pool);
    } else {
      console.warn('  WARNING: Reconciliation skipped (--skip-reconciliation flag set)');
    }

    // Step 2: Execute analytical queries
    console.log('Querying cube...');
    const [snapshot, cohortSplit, weeklyTrend /* ... */] = await Promise.all([
      getPortfolioSnapshot(pool),
      getCohortSplit(pool),
      getWeeklyTrend(pool),
      // ... additional queries
    ]);

    // Step 3: Assemble document
    console.log('Assembling document...');
    const children = [
      heading('Weekly Email Infrastructure Review'),
      paragraph(`Window: ${argv.start} – ${argv.end}`, { italic: true, color: COLORS.muted }),
      ...buildPortfolioSnapshotSection(snapshot),
      ...buildCohortSplitSection(cohortSplit),
      // ...buildWeeklyTrendSection(weeklyTrend),
      // ...additional sections
    ];

    const doc = new Document({
      sections: [{ properties: {}, children }],
    });

    // Step 4: Write to disk
    const buffer = await Packer.toBuffer(doc);
    fs.writeFileSync(argv.output, buffer);
    console.log(`Report written: ${argv.output} (${buffer.length} bytes)`);

  } catch (err) {
    console.error('Report build failed:', err.message);
    process.exit(1);
  } finally {
    await pool.end();
  }
}


// ============================================================================
// Entry point
// ============================================================================

if (require.main === module) {
  buildReport().catch(err => {
    console.error('Unhandled error:', err);
    process.exit(1);
  });
}

module.exports = { buildReport };
