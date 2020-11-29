extern void dyld_enumerate_tlv_storage(/*dyld_tlv_state_change_handler*/void* handler);

int main()
{
	dyld_enumerate_tlv_storage(0);
	return 0;
}
