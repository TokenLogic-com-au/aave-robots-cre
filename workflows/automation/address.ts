import {z} from 'zod';
import {getAddress} from 'viem';

// Config addresses are typed by hand. viem checks EIP-55 casing strictly when
// encoding, so a wrong-case letter would fail the write path while reads keep
// working. Normalize on parse; an empty string is kept so handlers can skip it.
export const addressSchema = z.string().transform((a) => (a ? getAddress(a.toLowerCase()) : a));
