import datetime as dt
import os
import sys
import time

from psycopg2 import Error as psycopg2_error
import structlog

from ina228_module import INA228
from utilities import postgres

# Database
db_name: str = os.environ.get(
    "DB_NAME", default="Environment variable does not exist"
)
username_path: str = os.environ.get(
    "DB_USER_FILE", default="Environment variable does not exist"
)
password_path: str = os.environ.get(
    "DB_PASSWORD_FILE", default="Environment variable does not exist"
)

# Environment Variables
SYSTEM_ID: str | None = os.environ.get("SYSTEM_ID")
DEVICE_INSTANCE: int = int(os.environ.get("DEVICE_INSTANCE", default="1"))
DEVICE_PORT: str = os.environ.get(
    "DEVICE_PORT", default="Environment variable does not exist"
)
DEVICE_ADDRESS: int = int(os.environ.get("DEVICE_ADDRESS", default="0x40"), 0)
DEVICE_DESCRIPTION: str = os.environ.get(
    "DEVICE_DESCRIPTION", default="Environment variable does not exist"
)
DEVICE_LOCATION: str = os.environ.get(
    "DEVICE_LOCATION", default="Environment variable does not exist"
)
LOGGING_LEVEL: str = os.environ.get("LOGGING_LEVEL", default="INFO")
UPDATE_PERIOD_MS: int = int(os.environ.get("UPDATE_PERIOD_MS", default=1000))

# Set up JSON logging
structlog.configure(
    cache_logger_on_first_use=True,
    wrapper_class=structlog.make_filtering_bound_logger(LOGGING_LEVEL),
    processors=[
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.dict_tracebacks,
        structlog.processors.CallsiteParameterAdder(
            [
                structlog.processors.CallsiteParameter.FILENAME,
                structlog.processors.CallsiteParameter.FUNC_NAME,
                structlog.processors.CallsiteParameter.LINENO,
            ],
        ),
        structlog.processors.JSONRenderer(),
    ],
)

logger = structlog.get_logger()


def get_docker_secret(secret_path: str) -> str:
    """Read a Docker secret from the given file path.

    Args:
        secret_path (str): Path to the secret file.

    Returns:
        str: The secret value as a string.

    Raises:
        FileNotFoundError: If secret_path does not exist.
        PermissionError: If script lacks permissions to access the file specified at secret_path.
        IsADirectoryError: If secret_path is a directory and not a file.
    """
    try:
        with open(secret_path, "r") as secret_file:
            secret_value: str = secret_file.read().strip()
            return secret_value
    except FileNotFoundError as e:
        raise FileNotFoundError(
            f"Secret not found at path: {secret_path}"
        ) from e
    except PermissionError as e:
        raise PermissionError(
            f"Inadequate permissions for accessing secret file at path: {secret_path}"
        ) from e
    except IsADirectoryError as e:
        raise IsADirectoryError(
            f"Specified path is a directory: {secret_path}"
        ) from e

def main() -> None:
    """Main function to initialize and read from the INA3221 via I2C."""

    # Retrieve DB credentials
    try:
        db_user: str = get_docker_secret(username_path)
        db_password: str = get_docker_secret(password_path)
    except FileNotFoundError as e:
        logger.error(f"Failed to get DB secrets: {e}")
        sys.exit(1)
    except PermissionError as e:
        logger.error(f"Failed to get DB secrets: {e}")
        sys.exit(1)
    except IsADirectoryError as e:
        logger.error(f"Failed to get DB secrets: {e}")
        sys.exit(1)

    db_table_columns: str = (
        "timestamp TIMESTAMPTZ NOT NULL PRIMARY KEY, "
        "id TEXT NOT NULL, "
        "instance INT NOT NULL, "
        "description TEXT, "
        "status INT, "
        "location TEXT, "
        "bus_voltage NUMERIC, "
        "shunt_voltage NUMERIC, "
        "current NUMERIC, "
        "power NUMERIC, "
        "energy NUMERIC"
    )

    try:
        # Init table in PSQL database
        postgres.init_db_table(
            db_name,
            "postgres",
            db_user,
            db_password,
            5432,
            "ina228_data",
            db_table_columns,
        )
        logger.info("Database init successful")
    except psycopg2_error as e:
        logger.error(f"Database init error: {e}")

    try:
        enable: list[int] = [0, 1, 2]

        with INA228(
            DEVICE_INSTANCE,
            DEVICE_PORT,
            DEVICE_ADDRESS,
            DEVICE_DESCRIPTION,
            DEVICE_LOCATION,
            enable,
        ) as ina228:
            logger.info("Init complete")
            while True:
                bus_voltage = None
                shunt_voltage = None
                current = None
                power = None
                energy = None

                try:
                    bus_voltage = round(ina228.bus_voltage, 6)
                    shunt_voltage = round(ina228.shunt_voltage, 6)
                    current = round(ina228.current, 6)
                    power = round(ina228.power, 6)
                    energy = round(ina228.energy, 6)
                except OSError as e:
                    logger.error(f"Update failed: {e}")
                
                # Consolidate necessary data into tuple
                data: tuple = (
                    dt.datetime.now(dt.timezone.utc),
                    SYSTEM_ID,
                    ina228.instance,
                    ina228.description,
                    ina228.status,
                    ina228.location,
                    bus_voltage,
                    shunt_voltage,
                    current,
                    power,
                    energy,
                )

                try:
                    # Write data to database
                    postgres.write_db_table(
                        db_name,
                        "postgres",
                        db_user,
                        db_password,
                        5432,
                        "ina228_data",
                        data,
                    )
                    logger.info("Database write successful")
                except psycopg2_error as e:
                    logger.error(f"Database write error: {e}")

                time.sleep(UPDATE_PERIOD_MS / 1000)

    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
