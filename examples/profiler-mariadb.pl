#!/usr/bin/env perl
use v5.38;
use DBIx::Fast;

# Usage:
#   docker run -d --name mariadb-demo \
#     -e MARIADB_ROOT_PASSWORD=test123 \
#     -e MARIADB_DATABASE=demo \
#     -p 3307:3306 mariadb:latest
#
#   perl -Ilib examples/profiler-mariadb.pl mariadb://root:test123@127.0.0.1:3307/demo

my $dsn = shift @ARGV or die "Usage: $0 <mariadb-dsn>\n  Example: $0 mariadb://root:test123\@127.0.0.1:3307/demo\n";

my $db = DBIx::Fast->new( dsn => $dsn, tn => 0 );

say "Connected to MariaDB (driver: @{[$db->dbd]})";
say "=" x 60;

# Setup
$db->exec('DROP TABLE IF EXISTS demo_products');
$db->exec(q{
    CREATE TABLE demo_products (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        name       VARCHAR(255) NOT NULL,
        price      DECIMAL(10,2) DEFAULT 0,
        status     TINYINT DEFAULT 1,
        created_at DATETIME,
        updated_at DATETIME,
        INDEX idx_status (status),
        INDEX idx_name (name)
    ) ENGINE=InnoDB
});

# 1. Query Tracker

say "\n>>> 1. QUERY TRACKER";
say "-" x 60;

# Activate tracker (silent - no auto_print)
$db->tracker;

# Generate some traffic
for my $i (1..20) {
    $db->insert('demo_products',
        { name => "Product $i", price => 9.99 + $i, status => $i % 3 },
        time => 'created_at'
    );
}

$db->all('SELECT * FROM demo_products WHERE status = ?', 1);
$db->val('SELECT COUNT(*) FROM demo_products');
$db->hash('SELECT * FROM demo_products WHERE id = ?', 1);
$db->flat('SELECT name FROM demo_products WHERE price > ?', 15);
$db->up('demo_products', { price => 99.99 }, { id => 1 }, 'updated_at');
$db->delete('demo_products', { id => 20 });

# Show stats
say "\n  Query Statistics:";
my $stats = $db->tracker->get_stats;
printf "    Total queries:  %d\n",     $stats->{total_queries};
printf "    Total time:     %.4fs\n",  $stats->{total_time};
printf "    Avg time:       %.4fs\n",  $stats->{avg_time};
printf "    Min time:       %.4fs\n",  $stats->{min_time};
printf "    Max time:       %.4fs\n",  $stats->{max_time};
printf "    Queries/sec:    %.1f\n",   $stats->{queries_per_second};

# By type
say "\n  By Query Type:";
my $by_type = $db->tracker->get_detailed_stats;
for my $type (sort keys %$by_type) {
    printf "    %-8s count=%d  total=%.4fs  avg=%.4fs\n",
        $type, $by_type->{$type}{count},
        $by_type->{$type}{total_time},
        $by_type->{$type}{avg_time};
}

# Slow queries
say "\n  Top 3 Slowest Queries:";
my $slow = $db->tracker->get_slow_queries(3);
for my $i (0..$#$slow) {
    printf "    %d. %.4fs  %s\n", $i+1, $slow->[$i]{duration},
        substr($slow->[$i]{sql}, 0, 70);
}

# 2. MariaDB Profile: EXPLAIN

say "\n>>> 2. EXPLAIN QUERY";
say "-" x 60;

my $plan = $db->profiler->explain_query(
    'SELECT * FROM demo_products WHERE status = ? AND price > ?', 1, 10
);
for my $row (@$plan) {
    printf "  table=%s  type=%s  key=%s  rows=%s  Extra=%s\n",
        $row->{table}  // '-',
        $row->{type}   // '-',
        $row->{key}    // 'NULL',
        $row->{rows}   // '-',
        $row->{Extra}  // '-';
}

# 3. MariaDB Profile: Table Stats

say "\n>>> 3. TABLE STATS";
say "-" x 60;

my $tstats = $db->profiler->get_table_stats('demo_products');
for my $t (@$tstats) {
    printf "  Engine=%s  Rows=%s  Data=%s bytes  Index=%s bytes\n",
        $t->{engine}, $t->{table_rows},
        $t->{data_length}, $t->{index_length};
}

# 4. MariaDB Profile: Index Stats

say "\n>>> 4. INDEX STATS";
say "-" x 60;

my $istats = $db->profiler->get_index_stats('demo_products');
for my $idx (@$istats) {
    printf "  %-15s col=%-15s seq=%s  cardinality=%s\n",
        $idx->{index_name}, $idx->{column_name},
        $idx->{seq_in_index}, $idx->{cardinality} // 'NULL';
}

# 5. MariaDB Profile: Server Stats

say "\n>>> 5. SERVER STATS";
say "-" x 60;

my $srv = $db->profiler->get_stats;
say "  Global:";
for my $k (qw(Questions Slow_queries Com_select Com_insert Com_update Com_delete)) {
    printf "    %-20s %s\n", $k, $srv->{global}{$k} // 0;
}

# MariaDB Profile: Connections

say "\n>>> 6. CONNECTIONS";
say "-" x 60;

my $conns = $db->profiler->get_current_connections;
printf "  Total=%d  Active=%d  Sleeping=%d\n",
    $conns->{total_connections},
    $conns->{active},
    $conns->{sleeping};

# Cleanup
$db->exec('DROP TABLE IF EXISTS demo_products');

say "\n" . "=" x 60;

