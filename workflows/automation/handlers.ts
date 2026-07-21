import {cre, CronCapability, getNetwork, handler, type Runtime} from '@chainlink/cre-sdk';
import {type Config} from './types';
import {processAutomation} from './processAutomation';

export const createAutomationHandler = (
  chainName: string,
  mailboxAddress: string,
  automationAddress: string,
  checkData: string,
  name?: string,
) => {
  const robot = name ? `${name} (${automationAddress})` : automationAddress;
  return (runtime: Runtime<Config>): string => {
    runtime.log(`[${chainName}] [${robot}] handler triggered`);

    const network = getNetwork({
      chainFamily: 'evm',
      chainSelectorName: chainName,
      isTestnet: false,
    });

    if (!network) {
      runtime.log(`Network not found: ${chainName}`);
      return 'Network not found';
    }

    const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector);

    try {
      const txHash = processAutomation(
        runtime,
        evmClient,
        automationAddress,
        mailboxAddress,
        chainName,
        checkData,
        name,
      );
      return txHash ?? 'No upkeep needed';
    } catch (e) {
      runtime.log(`[${chainName}] [${robot}] processAutomation failed: ${e}`);
      return 'Processing failed';
    }
  };
};

export const createHandlers = (config: Config) => {
  const trigger = new CronCapability().trigger({schedule: config.schedule});

  return config.evms
    .filter((network) => network.chainName)
    .flatMap((network) =>
      network.automations
        .filter((automation) => automation.address)
        .map((automation) =>
          handler(
            trigger,
            createAutomationHandler(
              network.chainName,
              network.mailboxAddress,
              automation.address,
              automation.checkData,
              automation.name,
            ),
          ),
        ),
    );
};
