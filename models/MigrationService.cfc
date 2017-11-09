component singleton accessors="true" {

    property name="wirebox" inject="wirebox";
    property name="migrationsDirectory";
    property name="datasource";
    property name="defaultGrammar";

    /**
    * Run the next available migration in the desired direction.
    *
    * @direction The direction in which to look for the next available migration — `up` or `down`.
    * @callback  A callback to execute after the ran migration, if any.
    *
    * @return    The ran migration information struct
    */
    public struct function runNextMigration( required string direction, callback ) {
        if ( isNull( callback ) ) { callback = function() {}; }
        var migrations = findAll();

        for ( var migration in migrations ) {
            var canMigrateInDirection = migration[ "canMigrate#direction#" ];
            if ( canMigrateInDirection ) {
                runMigration( arguments.direction, migration, callback );
                return migration;
            }
        }

        return {};
    }

    /**
    * Run all available migrations in the desired direction.
    *
    * @direction The direction for which to run the available migrations — `up` or `down`.
    * @callback  A callback to run after running each migration.
    *
    * @return    void
    */
    public void function runAllMigrations( direction, callback ) {
        if ( isNull( callback ) ) { callback = function() {}; }
        var migrations = arrayFilter( findAll(), function( migration ) {
            return direction == "up" ? !migration.migrated : migration.migrated;
        } );

        if ( direction == "down" ) {
            // sort in reversed order to get which migrations can be brought down
            arraySort( migrations, function( a, b ) {
                return dateCompare( b.timestamp, a.timestamp );
            } );
        }

        arrayEach( migrations, function( migration ) {
            runMigration( direction, migration, callback );
        } );
    }

    public array function findAll() {
        var migrationTableInstalled = isMigrationTableInstalled();

        var objectsQuery = directoryList( path = expandPath( migrationsDirectory ), listInfo = "query" );
        var objectsArray = [];
        for ( var row in objectsQuery ) {
            arrayAppend( objectsArray, row );
        }
        var onlyCFCs = arrayFilter( objectsArray, function( object ) {
            return object.type == "File" && right( object.name, 4 ) == ".cfc";
        } );

        var prequisitesInstalled = true;
        var migrations = arrayMap( onlyCFCs, function( file ) {
            var timestampString = left( file.name, 17 );
            var timestampParts = listToArray( timestampString, "_" );
            var timestamp = createDateTime(
                timestampParts[1],
                timestampParts[2],
                timestampParts[3],
                mid( timestampParts[ 4 ], 1, 2 ),
                mid( timestampParts[ 4 ], 3, 2 ),
                mid( timestampParts[ 4 ], 5, 2 )
            );

            var componentName = left( file.name, len( file.name ) - 4 );
            var migrationRan = migrationTableInstalled ? isMigrationRan( componentName ) : false;

            var migration = {
                fileName = file.name,
                componentName = componentName,
                absolutePath = file.directory & "/" & file.name,
                componentPath = migrationsDirectory & "/" & componentName,
                timestamp = timestamp,
                migrated = migrationRan,
                canMigrateUp = !migrationRan && prequisitesInstalled,
                canMigrateDown = migrationRan,
                migratedDate = ""
            };

            prequisitesInstalled = migrationRan;

            return migration;
        } );

        if ( ! migrationTableInstalled && ! arrayIsEmpty( migrations ) ) {
            arrayEach( migrations, function( migration ) {
                migration.canMigrateUp = false;
                migration.canMigrateDown = false;
            } );

            // sort in the correct order
            arraySort( migrations, function( a, b ) {
                return dateCompare( a.timestamp, b.timestamp );
            } );

            return migrations;
        }

        // sort in reversed order to get which migrations can be brought down
        arraySort( migrations, function( a, b ) {
            return dateCompare( b.timestamp, a.timestamp );
        } );

        var laterMigrationsNotInstalled = true;
        arrayEach( migrations, function( migration ) {
            migration.canMigrateDown = migration.migrated && laterMigrationsNotInstalled;
            laterMigrationsNotInstalled = !migration.migrated;
        } );

        // sort in the correct order
        arraySort( migrations, function( a, b ) {
            return dateCompare( a.timestamp, b.timestamp );
        } );

        return migrations;
    }

    public boolean function hasMigrationsToRun( direction ) {
        return ! arrayIsEmpty( arrayFilter( findAll(), function( migration ) {
            return direction == "up" ? !migration.migrated : migration.migrated;
        } ) );
    }

    public void function install( runAll = false ) {
        if ( isMigrationTableInstalled() ) {
            return;
        }

        queryExecute(
            "
                CREATE TABLE cfmigrations (
                    name VARCHAR(200) NOT NULL,
                    migration_ran #getDateTimeColumnType()# NOT NULL,
                    PRIMARY KEY (name)
                )
            ",
            {},
            { datasource = getDatasource() }
        );

        if ( runAll ) {
            runAllMigrations( "up" );
        }
    }

    public void function uninstall() {
        if ( ! isMigrationTableInstalled() ) {
            return;
        }

        runAllMigrations( "down" );

        queryExecute( "DROP TABLE cfmigrations", {}, { datasource = getDatasource() } );
    }

    public boolean function isMigrationTableInstalled() {
        cfdbinfo( name = "results" type = "Tables", datasource = getDatasource() );
        for ( var row in results ) {
            if ( row.table_name == "cfmigrations" ) {
                return true;
            }
        }
        return false;
    }

    public void function runMigration( direction, migrationStruct, callback ) {
        install();

        var componentName = replaceNoCase( migrationStruct.componentPath, migrationsDirectory & "/", "" );
        var migrationRan = isMigrationRan( componentName );

        if ( migrationRan && direction == "up" ) {
            throw("Cannot run a migration that has already been ran.");
        }

        if ( ! migrationRan && direction == "down" ) {
            throw("Cannot rollback a migration if it hasn't been ran yet.");
        }

        var migration = wirebox.getInstance( migrationStruct.componentPath );
        var migrationMethod = migration[ direction ];

        var schema = wirebox.getInstance( "SchemaBuilder@qb" ).setGrammar(
            wirebox.getInstance( "#defaultGrammar#@qb" )
        );

        var query = wirebox.getInstance( "QueryBuilder@qb" ).setGrammar(
            wirebox.getInstance( "#defaultGrammar#@qb" )
        );

        migrationMethod( schema, query );

        logMigration( direction, migrationStruct.componentPath );

        callback( migrationStruct );
    }

    private boolean function isMigrationRan( componentName ) {
        var migrations = queryExecute(
            "
                SELECT name
                FROM cfmigrations
            ",
            {},
            { datasource = getDatasource() }
        );

        for ( var migration in migrations ) {
            if ( migration.name == componentName ) {
                return true;
            }
        }
        return false;
    }

    private string function getDateTimeColumnType() {
        cfdbinfo( name = "results" type = "Version", datasource = getDatasource() );

        switch( results.database_productName ) {
            case "PostgreSQL"           : return "TIMESTAMP";
            case "MySQL"                : return "DATETIME";
            case "Microsoft SQL Server" : return "DATETIME";
            case "Oracle"               : return "DATE";
            default                     : return "DATETIME";
        }
    }

    private void function logMigration( direction, componentPath ) {
        var componentName = replaceNoCase( componentPath, migrationsDirectory & "/", "" );
        if ( direction == "up" ) {
            queryExecute(
                "INSERT INTO cfmigrations VALUES ( :name, :time )",
                { name = componentName, time = { value = now(), cfsqltype = "CF_SQL_TIMESTAMP" } },
                { datasource = getDatasource() }
            );
        } else {
            queryExecute(
                "DELETE FROM cfmigrations WHERE name = :name",
                { name = componentName },
                { datasource = getDatasource() }
            );
        }
    }

}
