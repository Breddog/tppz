from .base import SdrSource


def create_source(sdr_cfg) -> SdrSource:
    """Фабрика приймача за конфігом."""
    if sdr_cfg.driver == "sim":
        from .simulated import SimulatedSource
        return SimulatedSource()
    from .soapy import SoapySource
    src = SoapySource(sdr_cfg.device_args, ppm=sdr_cfg.ppm)
    src.stream_format = getattr(sdr_cfg, "stream_format", "auto")
    return src


__all__ = ["SdrSource", "create_source"]
