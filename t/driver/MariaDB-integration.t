use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBIx::Fast;

plan skip_all => "DBIX_FAST_TEST_MARIADB not set"
  unless $ENV{DBIX_FAST_TEST_MARIADB};

eval "use DBD::MariaDB 1.23";
plan skip_all => "DBD::MariaDB 1.23 required" if $@;

my $dsn = $ENV{DBIX_FAST_TEST_MARIADB};

# --- Connection ---

subtest 'Connection via URI' => sub {
    my $db;
    lives_ok { $db = DBIx::Fast->new( dsn => $dsn, tn => 0 ) } 'Connect via URI DSN';
    isa_ok( $db, 'DBIx::Fast' );
    is( $db->dbd, 'MariaDB', 'Driver detected as MariaDB' );
    ok( $db->dsn =~ /^dbi:MariaDB:/, 'DSN converted to DBI format' );
};

my $db = DBIx::Fast->new( dsn => $dsn, tn => 0 );

# --- Setup: generic e-commerce schema ---

for my $t (qw(order_items orders items users)) {
    $db->exec("DROP TABLE IF EXISTS $t");
}

$db->exec(q{
    CREATE TABLE users (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        email VARCHAR(255),
        password_hash VARCHAR(255),
        active TINYINT DEFAULT 1,
        created_at DATETIME,
        last_login DATETIME
    ) ENGINE=InnoDB
});

$db->exec(q{
    CREATE TABLE items (
        id INT AUTO_INCREMENT PRIMARY KEY,
        sku VARCHAR(100),
        title VARCHAR(255),
        price DECIMAL(10,2) DEFAULT 0,
        status TINYINT DEFAULT 1,
        created_at DATETIME,
        updated_at DATETIME
    ) ENGINE=InnoDB
});

$db->exec(q{
    CREATE TABLE orders (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT,
        total DECIMAL(10,2) DEFAULT 0,
        status INT DEFAULT 1,
        created_at DATETIME,
        blocked TINYINT DEFAULT 0,
        FOREIGN KEY (user_id) REFERENCES users(id)
    ) ENGINE=InnoDB
});

$db->exec(q{
    CREATE TABLE order_items (
        id INT AUTO_INCREMENT PRIMARY KEY,
        order_id INT,
        item_id INT,
        qty INT DEFAULT 1,
        price DECIMAL(10,2),
        FOREIGN KEY (order_id) REFERENCES orders(id),
        FOREIGN KEY (item_id) REFERENCES items(id)
    ) ENGINE=InnoDB
});

# --- Insert with time column ---

subtest 'insert with time column' => sub {
    lives_ok {
        $db->insert('users', {
            name          => 'Alice',
            email         => 'alice@example.com',
            password_hash => 'hashed_pw',
        }, time => 'created_at');
    } 'Insert user with time';

    my $row = $db->hash('SELECT * FROM users WHERE email = ?', 'alice@example.com');
    ok( $row, 'User inserted' );
    ok( $row->{created_at}, 'Time column auto-populated' );
    like( $row->{created_at}, qr/^\d{4}-\d{2}-\d{2}/, 'MySQL datetime format' );
};

# --- last_id ---

my $uid;
subtest 'last_id after insert' => sub {
    $uid = $db->last_id;
    ok( $uid, 'last_id is set' );
    ok( $uid > 0, 'last_id is positive' );

    my $name = $db->val('SELECT name FROM users WHERE id = ?', $uid);
    is( $name, 'Alice', 'last_id matches inserted user' );
};

# --- Insert items ---

my ($iid1, $iid2, $iid3);
subtest 'insert items' => sub {
    $db->insert('items', {
        sku   => 'SKU-001',
        title => 'Widget Pro',
        price => 29.99,
    }, time => 'created_at');
    $iid1 = $db->last_id;

    $db->insert('items', {
        sku   => 'SKU-002',
        title => 'Gadget Plus',
        price => 49.99,
    }, time => 'created_at');
    $iid2 = $db->last_id;

    $db->insert('items', {
        sku    => 'SKU-003',
        title  => 'Basic Thing',
        price  => 9.99,
        status => 0,
    }, time => 'created_at');
    $iid3 = $db->last_id;

    ok( $iid1 && $iid2 && $iid3, '3 items inserted with IDs' );
    ok( $iid3 > $iid2 && $iid2 > $iid1, 'IDs are sequential' );
};

# --- Insert order with FK ---

my $oid;
subtest 'insert order with FK' => sub {
    $db->insert('orders', {
        user_id => $uid,
        total   => 79.98,
        status  => 1,
    }, time => 'created_at');
    $oid = $db->last_id;
    ok( $oid, 'Order inserted with user FK' );
};

# --- Insert order_items (N:M) ---

subtest 'insert order_items' => sub {
    $db->insert('order_items', {
        order_id => $oid,
        item_id  => $iid1,
        qty      => 1,
        price    => 29.99,
    });
    my $id1 = $db->last_id;

    $db->insert('order_items', {
        order_id => $oid,
        item_id  => $iid2,
        qty      => 1,
        price    => 49.99,
    });
    my $id2 = $db->last_id;

    ok( $id1 && $id2, 'Order items linked' );
};

# --- hash() ---

subtest 'hash() single row' => sub {
    my $user = $db->hash('SELECT * FROM users WHERE id = ?', $uid);
    is( ref $user, 'HASH', 'hash returns hashref' );
    is( $user->{name}, 'Alice', 'Correct user data' );
    is( $user->{email}, 'alice@example.com', 'Email matches' );
    is( $db->results->{name}, 'Alice', '$results also set' );
};

# --- val() ---

subtest 'val() scalar queries' => sub {
    my $count = $db->val('SELECT COUNT(*) FROM items WHERE status = ?', 1);
    is( $count, 2, 'val COUNT returns scalar' );

    my $total = $db->val('SELECT total FROM orders WHERE id = ?', $oid);
    is( $total, '79.98', 'val returns single value' );

    my $max = $db->val('SELECT MAX(price) FROM items');
    is( $max, '49.99', 'val with aggregate' );
};

# --- all() ---

subtest 'all() multiple rows' => sub {
    my $rows = $db->all('SELECT * FROM items ORDER BY id');
    is( ref $rows, 'ARRAY', 'all returns arrayref' );
    is( scalar @$rows, 3, '3 items returned' );
    is( $rows->[0]->{title}, 'Widget Pro', 'First item correct' );

    $rows = $db->all('SELECT * FROM items WHERE status = ? ORDER BY id', 1);
    is( scalar @$rows, 2, 'Filtered to 2 active items' );
};

# --- all() with JOIN ---

subtest 'all() with JOIN' => sub {
    my $rows = $db->all(q{
        SELECT o.id as order_id, o.total, u.name as user_name,
               oi.qty, i.title as item_title
        FROM orders o
        JOIN users u ON u.id = o.user_id
        JOIN order_items oi ON oi.order_id = o.id
        JOIN items i ON i.id = oi.item_id
        WHERE o.id = ?
        ORDER BY i.title
    }, $oid);

    is( scalar @$rows, 2, 'JOIN returns 2 order lines' );
    is( $rows->[0]->{user_name}, 'Alice', 'User name from JOIN' );

    my @titles = map { $_->{item_title} } @$rows;
    ok( (grep { $_ eq 'Widget Pro' } @titles), 'Widget Pro in order' );
    ok( (grep { $_ eq 'Gadget Plus' } @titles), 'Gadget Plus in order' );
};

# --- flat() ---

subtest 'flat() column list' => sub {
    my @skus = $db->flat('SELECT sku FROM items ORDER BY id');
    is( scalar @skus, 3, 'flat returns 3 values' );
    is( $skus[0], 'SKU-001', 'First sku correct' );
    is( $skus[2], 'SKU-003', 'Third sku correct' );
};

# --- up() without time ---

subtest 'up() without time' => sub {
    $db->up('users', { active => 0 }, { id => $uid });

    my $val = $db->val('SELECT active FROM users WHERE id = ?', $uid);
    is( $val, 0, 'active updated to 0' );
};

# --- up() with time ---

subtest 'up() with time column' => sub {
    $db->up('items', { price => 19.99 }, { id => $iid1 }, 'updated_at');

    my $row = $db->hash('SELECT price, updated_at FROM items WHERE id = ?', $iid1);
    is( $row->{price}, '19.99', 'Price updated' );
    ok( $row->{updated_at}, 'Time column auto-set by up()' );
};

# --- update() with sen/where ---

subtest 'update() with sen/where' => sub {
    $db->update('orders', {
        sen   => { status => 2 },
        where => { id => $oid },
    });

    my $status = $db->val('SELECT status FROM orders WHERE id = ?', $oid);
    is( $status, 2, 'Order status updated via update()' );
};

# --- update() with time ---

subtest 'update() with time' => sub {
    $db->update('orders', {
        sen   => { blocked => 1 },
        where => { id => $oid },
    }, time => 'created_at');

    my $row = $db->hash('SELECT blocked, created_at FROM orders WHERE id = ?', $oid);
    is( $row->{blocked}, 1, 'Blocked flag set' );
    ok( $row->{created_at}, 'created_at time column updated' );
};

# --- delete() ---

subtest 'delete()' => sub {
    my $before = $db->val('SELECT COUNT(*) FROM order_items WHERE order_id = ?', $oid);
    is( $before, 2, '2 order items before delete' );

    $db->delete('order_items', { order_id => $oid });

    my $after = $db->val('SELECT COUNT(*) FROM order_items WHERE order_id = ?', $oid);
    is( $after, 0, '0 order items after delete' );
};

# --- last_sql ---

subtest 'last_sql tracking' => sub {
    $db->val('SELECT 1');
    like( $db->last_sql, qr/SELECT 1/, 'last_sql after val()' );

    $db->all('SELECT * FROM users');
    like( $db->last_sql, qr/SELECT \* FROM users/, 'last_sql after all()' );

    $db->up('users', { active => 1 }, { id => $uid });
    like( $db->last_sql, qr/UPDATE/, 'last_sql after up()' );
};

# --- execute() named params ---

subtest 'execute() with named params' => sub {
    $db->execute(
        'SELECT * FROM users WHERE name = :name AND email = :email',
        { name => 'Alice', email => 'alice@example.com' }
    );
    my $rows = $db->results;
    ok( $rows, 'execute with named params returned results' );
    is( scalar @$rows, 1, 'Found 1 user' );
    is( $rows->[0]->{name}, 'Alice', 'Correct user via named params' );
};

# --- now() ---

subtest 'now() timestamp' => sub {
    my $ts = $db->now();
    like( $ts, qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/, 'MySQL datetime format' );
};

# --- Error handling ---

subtest 'errors and last_error' => sub {
    my $db_err = DBIx::Fast->new( dsn => $dsn, tn => 0, RaiseError => 0, PrintError => 0 );

    $db_err->set_error( 42, 'Test error message' );
    ok( $db_err->last_error, 'last_error populated' );
    like( $db_err->last_error, qr/Test error message/, 'Error message correct' );
    is( scalar @{ $db_err->errors }, 1, 'errors array has 1 entry' );

    $db_err->set_error( 99, 'Another error' );
    is( scalar @{ $db_err->errors }, 2, 'errors array grows' );
};

# --- Transaction commit ---

subtest 'transaction commit' => sub {
    lives_ok {
        $db->txn(sub {
            $db->insert('users', { name => 'TxnUser', email => 'txn@example.com' });
        });
    } 'Transaction committed';

    my $found = $db->val('SELECT COUNT(*) FROM users WHERE name = ?', 'TxnUser');
    is( $found, 1, 'TxnUser persisted after commit' );
};

# --- Transaction rollback ---

subtest 'transaction rollback' => sub {
    eval {
        $db->txn(sub {
            $db->insert('users', { name => 'RollbackUser', email => 'rb@example.com' });
            die "force rollback";
        });
    };
    like( $@, qr/force rollback/, 'Transaction died' );

    my $found = $db->val('SELECT COUNT(*) FROM users WHERE name = ?', 'RollbackUser');
    is( $found, 0, 'RollbackUser NOT persisted after rollback' );
};

# --- Bulk operations ---

subtest 'bulk insert + count' => sub {
    my $before = $db->val('SELECT COUNT(*) FROM items');

    for my $i (1..100) {
        $db->insert('items', {
            sku   => "BULK-$i",
            title => "Bulk Item $i",
            price => 1.00 + ($i * 0.01),
        });
    }

    my $after = $db->val('SELECT COUNT(*) FROM items');
    is( $after - $before, 100, '100 bulk items inserted' );

    my $sum = $db->val('SELECT SUM(price) FROM items WHERE sku LIKE ?', 'BULK-%');
    ok( $sum > 100, 'Sum of bulk prices > 100' );
};

# --- Cleanup ---

for my $t (qw(order_items orders items users)) {
    $db->exec("DROP TABLE IF EXISTS $t");
}

done_testing();
