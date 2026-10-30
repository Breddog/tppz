from .base import SdrSource


def create_source(sdr_cfg) -> SdrSource:
    """Фабрика приймача за конфігом."""
    if sdr_cfg.driver == "sim":
        from .simulated import SimulatedSource
        return SimulatedSource()
    from .soapy import SoapySource
    return SoapySource(sdr_cfg.device_args, ppm=sdr_cfg.ppm)


__all__ = ["SdrSource", "create_source"]
