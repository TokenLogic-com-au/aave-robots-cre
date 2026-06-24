import {Runner} from '@chainlink/cre-sdk';
import {configSchema, type Config} from './types';
import {createHandlers} from './handlers';

export async function main() {
  const runner = await Runner.newRunner<Config>({configSchema});
  await runner.run(createHandlers);
}

main();
