import { config } from "dotenv";
import { join } from "node:path";

const DEVNET_ENV_PATH = join(import.meta.dirname, "../../../devnet/.env");

config();
config({ path: DEVNET_ENV_PATH, override: false });

if (!process.env.PRIVATE_KEY && process.env.RICH_L1_PRIVATE_KEY) {
  process.env.PRIVATE_KEY = process.env.RICH_L1_PRIVATE_KEY;
}
