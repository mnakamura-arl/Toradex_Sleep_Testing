from typing import Any

import psycopg2
from psycopg2._psycopg import connection
from psycopg2._psycopg import cursor
import structlog

# Get the logger as configured in __main__.py
logger = structlog.get_logger()

def init_db_table(
    db_name: str,
    db_ip: str,
    db_user: str,
    db_password: str,
    db_port: int,
    table_name: str,
    table_fields: str,
) -> None:
    """Create a table in the PostgreSQL database.

    Args:
        db_name (str): Name of the database.
        db_ip (str): Database host address.
        db_user (str): Username to authenticate.
        db_password (str): Password to authenticate.
        db_port (int): Connection port number.
        table_name (str): Name of the table to create.
        table_fields (str): Table columns specified in SQL syntax (e.g. temperature NUMERIC, name TEXT)).

    Raises:
        psycopg2.Error: If incorrect PSQL connection parameters are used.
        psycopg2.Error: If table initialization failed.
    """
    logger.debug(f"Initializing table {table_name} with fields {table_fields} in database {db_name} at {db_ip}:{db_port}")

    try:
        conn: connection = psycopg2.connect(
            database=db_name,
            host=db_ip,
            user=db_user,
            password=db_password,
            port=db_port,
        )
    except psycopg2.Error as e:
        logger.error(f"Invalid connection parameters: {e}", exc_info=True)
        raise

    curs: cursor = conn.cursor()

    try:
        with conn, curs:
            command: str = (f"CREATE TABLE IF NOT EXISTS {table_name} ({table_fields});")
            curs.execute(command)

        logger.info(f"Successfully initialized table {table_name} in database {db_name}")
    except psycopg2.Error as e:
        logger.error(f"Failed to init table {table_name} in database {db_name}: {e}", exc_info=True)
        raise
    finally:
        conn.close()

def write_db_table(
    db_name: str,
    db_ip: str,
    db_user: str,
    db_password: str,
    db_port: int,
    table_name: str,
    table_data: tuple[Any,...],
) -> None:
    """Insert data into PostgreSQL database.

    Args:
        db_name (str): Name of the database.
        db_ip (str): Database host address.
        db_user (str): Username to authenticate.
        db_password (str): Password to authenticate.
        db_port (int): Connection port number.
        table_name (str): Name of the table to insert data into.
        table_data (tuple[Any,...]): Data to insert into table.

    Raises:
        psycopg2.Error: If incorrect PSQL connection parameters are used.
        psycopg2.Error: If database write failed.
    """
    logger.debug(f"Writing to table {table_name} with data {table_data} in database {db_name} at {db_ip}:{db_port}")
    try:
        conn: connection = psycopg2.connect(
            database=db_name,
            host=db_ip,
            user=db_user,
            password=db_password,
            port=db_port,
        )
    except psycopg2.Error as e:
        logger.error(f"Invalid connection parameters: {e}", exc_info=True)
        raise

    curs: cursor = conn.cursor()

    try:
        with conn, curs:
            command: str = (
                f"INSERT INTO {table_name} VALUES ({('%s, ' * len(table_data)).removesuffix(', ')})"
            )
            curs.execute(command, table_data)
            logger.info(f"Successfully wrote to table {table_name} in database {db_name}")
    except psycopg2.Error as e:
        logger.error(f"Failed to write to table {table_name} in database {db_name}: {e}", exc_info=True)
        raise
    finally:
        conn.close()

def drop_db_table(
    db_name: str,
    db_ip: str,
    db_user: str,
    db_password: str,
    db_port: int,
    table_name: str,
) -> None:
    """Delete a table in the PostgreSQL database.

    Args:
        db_name (str): Name of the database.
        db_ip (str): Database host address.
        db_user (str): Username to authenticate.
        db_password (str): Password to authenticate.
        db_port (int): Connection port number.
        table_name (str): Name of the table to drop.

    Raises:
        psycopg2.Error: If incorrect PSQL connection parameters are used.
        psycopg2.Error: If database drop table failed.
    """
    logger.debug(f"Dropping table {table_name} in database {db_name} at {db_ip}:{db_port}")
    try:
        conn: connection = psycopg2.connect(
            database=db_name,
            host=db_ip,
            user=db_user,
            password=db_password,
            port=db_port,
        )
    except psycopg2.Error as e:
        logger.error(f"Invalid connection parameters: {e}", exc_info=True)
        raise

    curs: cursor = conn.cursor()

    try:
        with conn, curs:
            command: str = (
                f"DROP TABLE {table_name}")
            curs.execute(command)
            logger.info(f"Successfully dropped table {table_name} in database {db_name}")

    except psycopg2.Error as e:
        logger.error(f"Failed to drop table {table_name} in database {db_name}: {e}", exc_info=True)
        raise
    finally:
        conn.close()
