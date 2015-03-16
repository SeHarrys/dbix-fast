# dbix-fast

  my $d = DBIx::Fast->new( db => 'test' , user => 'test' , passwd => 'test');

  my $d = DBIx::Fast->new( db => 'test' , user => 'test' , passwd => 'test',
                           trace => '1' , profile => '!Statement:!MethodName' );

 for (qw(cc co ce)) { $d->execute('SELECT * FROM '.$_); }

 print Dumper $d->errors;

 $d->all('SELECT * FROM test WHERE 1');

 print Dumper $d->results;

 $d->all('SELECT * FROM test WHERE expire > ?',$time);

 my $all = $d->results;

 $d->hash('SELECT * FROM test WHERE id = ?,$id);

 my $hash = $d->results;
 
 $d->insert('test',
           {
               name => 'tester',
               status => 0
           }, time => 'date' );

 $d->delete('test', { id => $d->last_id });

 $d->delete('test', { id => 1 });

 say $d->last_id;

 $d->update('test', {
    		       sen   => { uid => 1 , name => 'EoArys' ,status => 1 },
		       where => { id => 33 },
           }, time => 'update_time'
    );
