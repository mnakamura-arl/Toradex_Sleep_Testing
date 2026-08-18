"""SMBus-backed replacements for the Adafruit CircuitPython bus/register helpers.

Provides drop-in equivalents of:
  * adafruit_bus_device.i2c_device.I2CDevice
  * adafruit_register.i2c_bit.ROBit / RWBit
  * adafruit_register.i2c_bits.ROBits / RWBits
  * adafruit_register.i2c_struct.ROUnaryStruct / UnaryStruct

built on smbus2 instead of busio/CircuitPython, so drivers written against the
Adafruit register API (e.g. ina228_module.INA2XX) run unmodified on plain
Linux i2c-dev buses.

The register descriptors expect the owning object to have an ``i2c_device``
attribute holding an :class:`I2CDevice`.

The module-level helper functions below are the utilities shared across the
metoc sensor services.
"""

import struct
import time

from smbus2 import SMBus, i2c_msg


def write_command(bus: SMBus, address: int, command: list[int]) -> None:
    """Send a command to the specified address on the bus.

    Args:
        bus (SMBus): I2C bus to utilize.
        address (int): I2C address of sensor.
        command (list[int]): Start register (1 byte) followed by data to write.
    """
    bus.write_i2c_block_data(address, command[0], command[1:])
    time.sleep(0.01)  # Small delay for the command to process


def read_data(bus: SMBus, address: int, register: int, length: int) -> list[int]:
    """Read data from the register.

    Args:
        bus (SMBus): I2C bus to utilize.
        address (int): I2C address.
        register (int): Start register.
        length (int): Length of block to read.
    """
    return bus.read_i2c_block_data(address, register, length)


def calculate_crc(data: list[int]) -> int:
    """Perform a cyclic redundancy check (CRC) for data verification.

    Args:
        data (list[Any]): Data to perform crc calculation on.
    """
    crc: int = 0xFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x80:
                crc = (crc << 1) ^ 0x31
            else:
                crc <<= 1
            crc &= 0xFF
    return crc


def validate_crc(data: list[int]) -> bool:
    """Validate the cyclic redundancy check (CRC) of the data.

    Args:
        data (list[Any]): Data to perform crc validation on.
    """
    value: list[int] = data[:2]
    crc_received: int = data[2]
    crc_calculated: int = calculate_crc(value)
    return crc_calculated == crc_received


class I2CDevice:
    """Represents a single device on an I2C bus.

    API-compatible subset of adafruit_bus_device.i2c_device.I2CDevice,
    backed by an smbus2 SMBus.

    Args:
        bus (SMBus): An open SMBus instance (e.g. SMBus(1) or SMBus("/dev/i2c-1")).
        address (int): 7-bit I2C address of the device.
        probe (bool): Probe for the device on init. Defaults to True.
    """

    def __init__(self, bus: SMBus, address: int, probe: bool = True) -> None:
        self._bus = bus
        self.device_address = address
        if probe:
            self._probe_for_device()

    def readinto(self, buffer: bytearray, *, start: int = 0, end: int | None = None) -> None:
        """Read into ``buffer[start:end]`` from the device.

        Args:
            buffer (bytearray): Buffer to read data into.
            start (int): Index to start writing at.
            end (int | None): Index to write up to, exclusive. Defaults to len(buffer).
        """
        if end is None:
            end = len(buffer)
        msg = i2c_msg.read(self.device_address, end - start)
        self._bus.i2c_rdwr(msg)
        buffer[start:end] = bytes(msg)

    def write(self, buffer: bytes | bytearray, *, start: int = 0, end: int | None = None) -> None:
        """Write ``buffer[start:end]`` to the device.

        Args:
            buffer (bytes | bytearray): Data to write.
            start (int): Index to start reading data from.
            end (int | None): Index to read up to, exclusive. Defaults to len(buffer).
        """
        if end is None:
            end = len(buffer)
        msg = i2c_msg.write(self.device_address, bytes(buffer[start:end]))
        self._bus.i2c_rdwr(msg)

    def write_then_readinto(
        self,
        out_buffer: bytes | bytearray,
        in_buffer: bytearray,
        *,
        out_start: int = 0,
        out_end: int | None = None,
        in_start: int = 0,
        in_end: int | None = None,
    ) -> None:
        """Write ``out_buffer[out_start:out_end]``, then read into
        ``in_buffer[in_start:in_end]`` within a single transaction
        (repeated START, no STOP in between).

        Args:
            out_buffer (bytes | bytearray): Data to write (typically a register address).
            in_buffer (bytearray): Buffer to read data into.
            out_start (int): Index to start reading output data from.
            out_end (int | None): Index to read output data up to, exclusive.
            in_start (int): Index to start writing input data at.
            in_end (int | None): Index to write input data up to, exclusive.
        """
        if out_end is None:
            out_end = len(out_buffer)
        if in_end is None:
            in_end = len(in_buffer)
        write_msg = i2c_msg.write(self.device_address, bytes(out_buffer[out_start:out_end]))
        read_msg = i2c_msg.read(self.device_address, in_end - in_start)
        self._bus.i2c_rdwr(write_msg, read_msg)
        in_buffer[in_start:in_end] = bytes(read_msg)

    def __enter__(self) -> "I2CDevice":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> bool:
        return False

    def _probe_for_device(self) -> None:
        try:
            self._bus.read_byte(self.device_address)
        except OSError as e:
            raise ValueError(
                f"No I2C device at address: 0x{self.device_address:02x}"
            ) from e


class RWBit:
    """Single bit register (read-write) within a multi-byte register.

    Values are bool.

    Args:
        register_address (int): Address of the register.
        bit (int): Bit index within the register (0 = LSB of the register value).
        register_width (int): Number of bytes in the register. Defaults to 1.
        lsb_first (bool): True if the low byte is transmitted first. Defaults to True.
    """

    def __init__(
        self,
        register_address: int,
        bit: int,
        register_width: int = 1,
        lsb_first: bool = True,
    ) -> None:
        self.bit_mask = 1 << (bit % 8)  # bitmask within the byte
        self.buffer = bytearray(1 + register_width)
        self.buffer[0] = register_address
        if lsb_first:
            self.byte = bit // 8 + 1  # byte index within the buffer
        else:
            self.byte = register_width - (bit // 8)

    def __get__(self, obj, objtype=None) -> bool:
        with obj.i2c_device as i2c:
            i2c.write_then_readinto(self.buffer, self.buffer, out_end=1, in_start=1)
        return bool(self.buffer[self.byte] & self.bit_mask)

    def __set__(self, obj, value: bool) -> None:
        with obj.i2c_device as i2c:
            i2c.write_then_readinto(self.buffer, self.buffer, out_end=1, in_start=1)
            if value:
                self.buffer[self.byte] |= self.bit_mask
            else:
                self.buffer[self.byte] &= ~self.bit_mask
            i2c.write(self.buffer)


class ROBit(RWBit):
    """Single bit register (read-only). See RWBit for arguments."""

    def __set__(self, obj, value: bool) -> None:
        raise AttributeError("Read-only bit cannot be set")


class RWBits:
    """Multi-bit register (read-write) within a multi-byte register.

    Values are int spanning ``lowest_bit`` through ``lowest_bit + num_bits - 1``.

    Args:
        num_bits (int): Number of bits in the field.
        register_address (int): Address of the register.
        lowest_bit (int): Lowest bit index of the field.
        register_width (int): Number of bytes in the register. Defaults to 1.
        lsb_first (bool): True if the low byte is transmitted first. Defaults to True.
        signed (bool): Interpret the field as two's complement. Defaults to False.
    """

    def __init__(
        self,
        num_bits: int,
        register_address: int,
        lowest_bit: int,
        register_width: int = 1,
        lsb_first: bool = True,
        signed: bool = False,
    ) -> None:
        self.bit_mask = ((1 << num_bits) - 1) << lowest_bit
        if self.bit_mask >= 1 << (register_width * 8):
            raise ValueError("Cannot have more bits than register size")
        self.lowest_bit = lowest_bit
        self.buffer = bytearray(1 + register_width)
        self.buffer[0] = register_address
        self.lsb_first = lsb_first
        self.sign_bit = (1 << (num_bits - 1)) if signed else 0

    def _reg_from_buffer(self) -> int:
        value = 0
        order = range(len(self.buffer) - 1, 0, -1)
        if not self.lsb_first:
            order = range(1, len(self.buffer))
        for i in order:
            value = (value << 8) | self.buffer[i]
        return value

    def _reg_to_buffer(self, value: int) -> None:
        order = range(len(self.buffer) - 1, 0, -1)
        if not self.lsb_first:
            order = range(1, len(self.buffer))
        for i in reversed(order):
            self.buffer[i] = value & 0xFF
            value >>= 8

    def __get__(self, obj, objtype=None) -> int:
        with obj.i2c_device as i2c:
            i2c.write_then_readinto(self.buffer, self.buffer, out_end=1, in_start=1)
        value = (self._reg_from_buffer() & self.bit_mask) >> self.lowest_bit
        if self.sign_bit and value >= self.sign_bit:
            value -= 2 * self.sign_bit
        return value

    def __set__(self, obj, value: int) -> None:
        value <<= self.lowest_bit
        with obj.i2c_device as i2c:
            i2c.write_then_readinto(self.buffer, self.buffer, out_end=1, in_start=1)
            reg = self._reg_from_buffer()
            reg &= ~self.bit_mask
            reg |= value
            self._reg_to_buffer(reg)
            i2c.write(self.buffer)


class ROBits(RWBits):
    """Multi-bit register (read-only). See RWBits for arguments."""

    def __set__(self, obj, value: int) -> None:
        raise AttributeError("Read-only bits cannot be set")


class UnaryStruct:
    """Whole register (read-write) decoded via a struct format with a single value.

    Args:
        register_address (int): Address of the register.
        struct_format (str): struct module format string for a single value,
            including byte order (e.g. ">H" for a big-endian unsigned 16-bit).
    """

    def __init__(self, register_address: int, struct_format: str) -> None:
        self.format = struct_format
        self.address = register_address

    def __get__(self, obj, objtype=None):
        buf = bytearray(1 + struct.calcsize(self.format))
        buf[0] = self.address
        with obj.i2c_device as i2c:
            i2c.write_then_readinto(buf, buf, out_end=1, in_start=1)
        return struct.unpack_from(self.format, buf, 1)[0]

    def __set__(self, obj, value) -> None:
        buf = bytearray(1 + struct.calcsize(self.format))
        buf[0] = self.address
        struct.pack_into(self.format, buf, 1, value)
        with obj.i2c_device as i2c:
            i2c.write(buf)


class ROUnaryStruct(UnaryStruct):
    """Whole register (read-only) decoded via a struct format. See UnaryStruct."""

    def __set__(self, obj, value) -> None:
        raise AttributeError("Read-only register cannot be set")
