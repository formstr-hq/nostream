import { getMasterDbClient } from "../src/database/client";
import { UserRepository } from "../src/repositories/user-repository";
import { User } from "../src/@types/user";

async function main() {
  const pubkey = process.argv[2];

  if (!pubkey || pubkey.length !== 64) {
    console.error("Usage: add-user <hex-pubkey>");
    process.exit(1);
  }

  const dbClient = getMasterDbClient();
  const userRepository = new UserRepository(dbClient);

  const now = new Date();

  const user: User = {
    pubkey,
    isAdmitted: true,
    tosAcceptedAt: now,
    balance: 0n,
    createdAt: now,
    updatedAt: now,
  };

  await userRepository.upsert(user);

  console.log(`✅ User admitted: ${pubkey}`);

  // Important: close pool or script will hang
  await dbClient.destroy();
  process.exit(0);
}

main().catch(async (err) => {
  console.error("❌ Failed to add user:", err);
  process.exit(1);
});
