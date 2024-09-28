#include "verilator_spi_bus.h"

#include "verilator_context.h"

#include <stdexcept>

namespace tt09_levenshtein
{

VerilatorSpiBus::VerilatorSpiBus(VerilatorContext& context, unsigned int clockDivider) noexcept
    : m_context(context)
    , m_clockDivider(clockDivider)
{
    m_context.top().spi_ss_n = 1;
}

asio::awaitable<std::byte> VerilatorSpiBus::execute(std::uint32_t command)
{
    auto lowClocks = m_clockDivider / 2;
    auto highClocks = m_clockDivider - lowClocks;

    auto& ss_n = m_context.top().spi_ss_n;
    auto& sck = m_context.top().spi_sck;
    auto& mosi = m_context.top().spi_mosi;
    const auto& miso = m_context.top().spi_miso;

    ss_n = 0;

    // Transmit bits
    for (unsigned int i = 0; i != 32; ++i)
    {
        sck = 0;
        mosi = command >> 31;
        co_await m_context.clocks(lowClocks);
        sck = 1;
        co_await m_context.clocks(highClocks);
        command <<= 1;
    }

    // Wait for response
    for (unsigned int i = 0; i != 1000; ++i)
    {
        sck = 0;
        co_await m_context.clocks(lowClocks);

        if (miso)
        {
            break;
        }

        sck = 1;
        co_await m_context.clocks(highClocks);
    }

    if (!miso)
    {
        ss_n = 1;
        sck = 0;
        co_await m_context.clocks(m_clockDivider);

        throw std::runtime_error("SPI error");
    }

    // Read response
    std::uint8_t resp = 0;
    for (unsigned int i = 0; i != 8; ++i)
    {
        sck = 1;
        co_await m_context.clocks(highClocks);

        sck = 0;
        co_await m_context.clocks(lowClocks);

        resp = (resp << 1) | (miso ? 1 : 0);
    }

    ss_n = 1;
    co_await m_context.clocks(m_clockDivider);

    co_return std::byte{resp};
}

} // namespace tt09_levenshtein