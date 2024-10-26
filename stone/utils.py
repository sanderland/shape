import logging


def setup_logging(level=logging.INFO):
    logging.basicConfig(level=level, format="[%(levelname)s] %(message)s")
    logger = logging.getLogger(__name__)
    return logger
