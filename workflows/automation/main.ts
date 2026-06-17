import { Runner } from '@chainlink/cre-sdk';
import { type Config } from './types';
import { createHandlers } from './handlers';

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(createHandlers);
}

main();
